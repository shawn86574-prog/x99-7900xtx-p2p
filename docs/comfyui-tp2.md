# ComfyUI MiniMax-H3 TP2：两进程单卡可见模式下的拓扑坑

本页记录一次把 RCCL TP2 接进 ComfyUI（MiniMax-H3 视频工作流）时踩到的拓扑问题，
以及它与 `scripts/gen-topo.sh` 原有约定的冲突。硬件与 P2P 强制方法见 README。

## 环境

| 项 | 值 |
| --- | --- |
| 平台 | X99-TF + Xeon E5 v4，BIOS 分叉 x8/x8 |
| 显卡 | 2× RX 7900 XTX（1002:744c, gfx1100），`0000:05:00.0` / `0000:08:00.0` |
| 拓扑 | 两卡同挂 `0000:04:00.0` PCIe switch，下行 16 GT/s x16，**上行 root port 8 GT/s x8** |
| RCCL | 系统 2.27.7；生产 torch 构建内报 "NCCL version 2.30.7" |
| 并行方式 | 两个 ComfyUI 进程，每进程 `HIP_VISIBLE_DEVICES=<rank>`，插件按头/输入维切 DiT |

## 冲突点：`dev` 字段的两种语义

`scripts/gen-topo.sh` 默认把 `dev` 写成 `rank`（`dev == rank`），这是**一个进程里看得见两张卡**时的写法：
本地设备号 0/1 与 XML 中的 dev 0/1 一一对应。

而 ComfyUI 这套并行是**每进程只可见一张卡**，进程内本卡恒为设备号 0。
若沿用 `dev == rank` 的产物，rank1 的“设备 0”会被表里的 `dev="0"`（即 rank0 的卡）接走，两端各自绑到同一张卡，RCCL 建 ring 时直接失败：

```text
ncclInternalError: Internal check failed.
Last error:
Ring 0: Asymmetric link! Rank 0 -> 1, but 1 -> 1
```

**修正**：用 `--single-visible` 生成单卡可见变体，产物里两张卡的 `dev` 都写 0，由 `rank` 属性区分归属：

```bash
bash scripts/gen-topo.sh --single-visible            # 默认写 topo/fake_topo_single.xml
sudo install -m 644 topo/fake_topo_single.xml /etc/p2p/topo-pxb-single.xml
```

两者是两份文件，互不覆盖：

| 启动方式 | 拓扑文件 | dev 语义 |
| --- | --- | --- |
| 一个进程看见两张卡（SGLang 等） | `/etc/p2p/topo-pxb.xml` | `dev == rank` |
| 每进程只看见一张卡（本方案） | `/etc/p2p/topo-pxb-single.xml` | `dev == 0` |

混用任意一种都会重现上面的 `Asymmetric link`。

## 启动器要点

P2P 通路：

```bash
HIP_VISIBLE_DEVICES=<rank> CUDA_VISIBLE_DEVICES=<rank> \
NCCL_TOPO_FILE=/etc/p2p/topo-pxb-single.xml NCCL_P2P_LEVEL=PXB \
<每 rank 一个 ComfyUI 进程>
```

- `NCCL_P2P_DISABLE` 必须**不设**（或为 0）。把它设成 1 会退回 host 通路，可用但更慢。
- 回退（host/SHM 通路）：删除 `NCCL_TOPO_FILE` / `NCCL_P2P_LEVEL`，并显式 `NCCL_P2P_DISABLE=1`，
  让 RCCL 自行探测真实的 PHB 布局。这条路径**不要**再用伪造拓扑。
- `/etc/profile.d/p2p-rccl.sh` 会把 `NCCL_TOPO_FILE` 和 `NCCL_P2P_LEVEL` 注入每个新 shell；
  单卡可见的启动器必须显式改写或清掉这两个变量，否则会拿到默认 `dev == rank` 的那一份。

## 实测

MiniMax-H3 int8、960×544、124 帧、10 步 euler、同一 prompt、同一份权重；
两次 TP2 均为文本编码器在 GPU 上（生产工作流的 `CLIPLoader` 也是 `device=default`）。

| 配置 | 稳态 s/step | 端到端 | 每卡峰值显存 | all_reduce |
| --- | --- | --- | --- | --- |
| 单卡 | 15.90–16.09 | 214.3 s | 23.86 GB | 0 |
| TP2 + P2P（单卡可见 + single 变体） | 11.57–11.75 | 172.4 / 179.2 s | 23.87 GB | 1004 次 / 193.35 GB |
| TP2 + host 通路（两卡可见 + 关 P2P） | 12.63–12.79 | 385.3 s* | 14.19 GB | 1004 次 / 193.35 GB |

\* 该轮为了压住显存峰值把文本编码器强制到 CPU，约多付 200 s，端到端不可与另外两行直接比较；
只看采样段：16.00 → 11.65 s/step 为 **1.37x**，host 通路为 1.26x。

补充观察：

- 两个 rank 输出的 md5 完全一致，切分（qkv 按头、out_proj/fc2 按输入维、fc1 按 gate/up）无损。
- 每次 all_reduce 后 bf16 累加，每步流量 19.3 GB；P2P 与 host 通路每步差约 1.05 s，
  与 5.03 / 4.1 GB/s 的实测带宽差一致。
- 11.65 s/step 已经贴近 Gen3 x8（上行）通信上限，继续优化要换平台而不是调拓扑。

## 边界

- 显存贴顶：TP2 每个进程都在 23.87/24 GB 徘徊，文本编码器阶段靠动态 VRAM 载入流式搬权重。
  在这种配置下不要再叠加会额外占显存的选项。
- 文本编码器在 TP2 里是两份拷贝（每 rank 各一份），只并行不共享；它不构成串行瓶颈，
  但会吃掉显存余量。
- 本次没有验证 ComfyUI 的 `--lowvram` 与 TP2 叠加；两者是否互斥需要在真实长视频工作流上另测。

## 补充实测（2026-11-03，2× RX 7900 XTX 24 GB）

环境：ComfyUI-AMD + `--use-ck-attention`，两个实例各占一张卡（8190 / 8191），P2P 模式
（`/etc/p2p/topo-pxb-single.xml`）。工作流：832×480、121 帧、4 步、w4a8 convrot DiT + turbo LoRA。

| 项目 | 冷启动（124 帧） | 权重复用（121 帧） |
| --- | --- | --- |
| 端到端 | 321.4 s | 79.4 s |
| 采样窗口 | — | 68 s（约 17 s/step） |
| rank0 / rank1 | 321.4 / 242.7 s | 79.4 / 79.4 s |
| 每卡峰值显存 | 23.98 / 23.88 GB | 23.71 / 23.76 GB |
| 两卡同时 busy | — | 62 / 68 s（91%） |
| 利用率均值 | — | card0 97.6% / card1 79.0% |

- 两 rank 输出 md5 一致（冷启动轮 `d2719b2c…`），切分逻辑无损。
- 冷启动与权重复用的差距来自加载：第二次起权重常驻显存，79.4 s 基本等于采样 + VAE 解码。
- `per_step=345.663` 这类字段与墙钟对不上，判断并行一律以墙钟 + `rocm-smi` 采样为准。

### 三个容易误判的坑

1. **同名工作流重复提交会命中 ComfyUI 缓存**：第二次起约 1 秒返回、第二张卡 0% 占用，
   看起来像“没并行”。每次验证改帧数/步数或 seed，强制 cache miss。
2. **`result.json` 的 `per_step` 不可信**：单位与口径不一致，用它算加速比会得出荒谬结论。
3. **两个实例共用输出目录**：产物落在 `out_r{0,1}/tp2/`，只取到一份 mp4 时无法做跨 rank
   哈希校验；验证时要分别取两边的同名输出。
