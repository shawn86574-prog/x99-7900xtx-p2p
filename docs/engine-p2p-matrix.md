# 引擎侧 P2P 生效矩阵：为什么 vLLM 里 P2P 会失效，以及怎么让它永远生效

> 2026-11-07 实测。样本：vLLM TP=2（Qwen3.8-27B-AWQ-INT4，`--port 30012`）+ ComfyUI TP2 双实例。
> 本文只讨论**第三层（运行时环境变量）**，内核层与拓扑层见 [report.md](report.md)。

## 一、结论先给

| 引擎 / 形态 | 每进程可见卡 | P2P 是否生效 | 证据 |
|---|---|---|---|
| ComfyUI TP2（双进程，各 `HIP_VISIBLE_DEVICES=$r`） | 1 张 | ✅ 生效 | 进程 env 内 `NCCL_TOPO_FILE` 指向单卡可见版拓扑 |
| **vLLM TP=2（单进程双卡可见）** | 2 张 | ✅ 生效（须 `/etc/rccl.conf`） | 修复后实测 `isAllDirectP2p 1` + `via P2P/IPC`，而 worker env 里 `NCCL_` 仅剩 `DEBUG` 两项 |
| SGLang TP=2（单进程双卡可见） | 2 张 | ✅ 生效（须 `/etc/rccl.conf`） | 实测 `isAllDirectP2p 1` + `via P2P/IPC`×6、`via SHM`×0；scheduler 进程 env 仅 20 个变量、`NCCL_` 只剩 `DEBUG` 两项 |
| Strata（层切分 + 专家并行） | 2 张 | — 与本机制无关 | 不走 RCCL，用 HIP `cudaMemcpyPeer` + 自带双向比对 |

**一句话**：P2P 能否生效，不取决于你 `source` 过什么脚本，而取决于**真正调用 RCCL 的那个进程**能不能读到 `NCCL_TOPO_FILE`。

## 二、vLLM 为什么失效（实测，可复现）

### 2.1 进程级证据

同一个 vLLM 实例的四类进程，`/proc/<pid>/environ` 实测：

| 进程 | PID | 变量总数 | `NCCL_TOPO_FILE` | `NCCL_P2P_DISABLE` | `NCCL_P2P_LEVEL` |
|---|---|---|---|---|---|
| `vllm serve`（driver） | 55252 | 126 | ✅ `/etc/p2p/topo-pxb.xml` | ✅ `0` | ✅ `PXB` |
| `VLLM::EngineCore` | 55396 | **17** | ❌ | ❌ | ❌ |
| `VLLM::Worker_TP0` | 55502 | **19** | ❌ | ❌ | ❌ |
| `VLLM::Worker_TP1` | 55503 | **19** | ❌ | ❌ | ❌ |

复现命令（任意时刻都成立）：

```bash
for p in $(pgrep -f "vllm serve") $(pgrep -f "VLLM::"); do
  printf 'pid=%s vars=%s NCCL=%s\n' "$p" \
    "$(tr '\0' '\n' < /proc/$p/environ | grep -c .)" \
    "$(tr '\0' '\n' < /proc/$p/environ | grep -c '^NCCL_')"
done
```

而 vLLM 日志明确写着 NCCL 是在 worker 里初始化的：

```
(Worker pid=37538) world_size=2 rank=0 local_rank=0 ... backend=nccl
```

**所以：driver 读到了伪造拓扑，但真正建通信子的 worker 读不到。**

### 2.2 这不是 Python multiprocessing 的锅

同版本 vLLM、同解释器下的对照实验：

```python
import os, multiprocessing as mp
os.environ['NCCL_TOPO_FILE'] = '/etc/p2p/topo-pxb.xml'
import vllm                                     # 触发 env_override / ROCm 平台初始化
mp.get_context('spawn').Process(target=child).start()
```

结果：`parent 129 → child 134`，`NCCL_TOPO_FILE` **保留**。

即标准 `spawn` 会完整继承。vLLM 这条 ROCm 路径在启动 EngineCore/Worker 时给出了一份**精简环境**（19 个变量全是它自己关心的调优项：`RCCL_DEBUG`、`HIP_FORCE_DEV_KERNARG`、`AITER_*`、`GLOG_*`、`TORCHINDUCTOR_*`、`OMP_NUM_THREADS` 等），用户注入的 `NCCL_*` 不在其中。

### 2.3 失效链

```
宿主 shell: NCCL_TOPO_FILE=/etc/p2p/topo-pxb.xml
      ↓  vllm serve 继承（driver 有）
   EngineCore / Worker：env 被重建 → NCCL_TOPO_FILE 丢失
      ↓  worker 内 RCCL 初始化
   读不到伪造拓扑 → 按真实路径 PHB(8) 判定
      ↓  RCCL 2.27.7 在 Intel x86 上强制 p2pLevel = PATH_PXB(5)
   PHB(8) > PXB(5) → 无直连路径 → 回落 SHM
```

结果就是：**内核 P2P 明明开着，vLLM 却仍然走主机内存中转**。

### 2.4 还有第二重原因：启动环境里 `NCCL_P2P_DISABLE=1`

实测旧实例（pid 55252）的 driver env：

```
NCCL_P2P_DISABLE=1      ← 显式关闭
NCCL_P2P_LEVEL=PXB
NCCL_TOPO_FILE=/etc/p2p/topo-pxb.xml
```

即使 §2.1 的 worker 环境问题不存在，这一条也会让 P2P 直接关掉。而且**环境变量优先级高于 `/etc/rccl.conf`**，所以配置文件救不了它 —— 必须在启动侧清掉。

### 2.5 修复后实测（决定性对照）

停掉旧实例，用**只保留 shell 环境、剔除全部 `NCCL_*`** 的方式重启，拓扑仅由 `/etc/rccl.conf` 提供：

```
[relaunch] env=123 个变量，NCCL_TOPO_FILE 已移除
MasterMonster:63117 [0] NCCL INFO Check P2P Type isAllDirectP2p 1 directMode 0
MasterMonster:63117 [0] NCCL INFO Channel 00/0 : 0[5000] -> 1[8000] via P2P/IPC
MasterMonster:63117 [0] NCCL INFO Channel 01/0 : 0[5000] -> 1[8000] via P2P/IPC
MasterMonster:63118 [1] NCCL INFO Channel 00/0 : 1[8000] -> 0[5000] via P2P/IPC
MasterMonster:63118 [1] NCCL INFO Channel 01/0 : 1[8000] -> 0[5000] via P2P/IPC
```

同时该实例的 worker 进程（真正建通信子的那两个）环境是：

| 进程 | 变量数 | `NCCL_*` |
|---|---|---|
| `VLLM::EngineCore` 63012 | 17 | 2（`NCCL_DEBUG`、`NCCL_DEBUG_SUBSYS`） |
| `VLLM::Worker_TP0` 63117 | 19 | 2（同上） |
| `VLLM::Worker_TP1` 63118 | 19 | 2（同上） |

**没有任何 `NCCL_TOPO_FILE` / `NCCL_P2P_DISABLE` / `NCCL_P2P_LEVEL`，P2P 依然生效** —— 这就是配置文件兜底的直接证明。

## 三、另外两个引擎

### 3.1 SGLang：同样依赖 `/etc/rccl.conf`（原判断已被实测推翻）

最初只看源码得出的结论是「标准 `mp.Process` spawn、无 env 白名单，所以会继承」——**实测否定了这个推断**。

以 `sglang-tp.sh start tp2` 启动（`--tp-size 2`、双卡可见），运行期实测：

| 进程 | PID | 变量数 | `NCCL_*` |
|---|---|---|---|
| `sglang.launch_server` | 66239 | 126 | 5 |
| `sglang::scheduler_TP0` | 66678 | **20** | **2**（仅 `NCCL_DEBUG`、`NCCL_DEBUG_SUBSYS`） |
| `sglang::scheduler_TP1` | 66679 | **20** | **2**（同上） |

真正建通信子的 scheduler 进程同样拿不到 `NCCL_TOPO_FILE`。日志却显示：

```
Check P2P Type isAllDirectP2p 1 directMode 0
Channel 00/0 : 0[5000] -> 1[8000] via P2P/IPC
Channel 01/0 : 1[8000] -> 0[5000] via P2P/IPC
```

`via P2P/IPC` 出现 6 次，`via SHM` 0 次 —— **拓扑完全来自 `/etc/rccl.conf`**。

结论修正：**vLLM 与 SGLang 都会重建子进程环境**，这不是某一家的特例，而是这类框架的共性。所以 `/etc/rccl.conf` 不是"vLLM 专用补丁"，而是两个框架的共同前提。

### 3.2 Strata：根本不用 RCCL

Strata 的跨卡是 HIP peer 直拷，不是集合通信。`src/core/peer_experts.cpp` 里有一段自检：

```cpp
// cudaDeviceCanAccessPeer 说 yes、cudaMemcpyPeerAsync 也返回成功，但数据根本没动
// （PHB 上 2×A4000 的经典坑）。所以一次性做双向小拷贝 + memcmp 验证。
bool p2p_copies_data(int device) { ... cudaMemcpyPeer(...); memcmp(back, h, kN*4) ... }
```

- 它只依赖**内核层**（`p2p_force` + amdgpu peer access），与 `NCCL_TOPO_FILE` 无关；
- 所以 vLLM 这个 bug **不会**影响 Strata；
- 反过来说，改 `/etc/rccl.conf` 也不会给 Strata 带来任何性能收益（它本来就不走 RCCL 的 P2P 判定）。

## 四、让它永远生效：`/etc/rccl.conf`

### 4.1 为什么是配置文件

`librccl.so.1` 内置了配置文件支持（strings 实证）：

```
/etc/rccl.conf
NCCL_CONF_FILE
Could not open kernel conf file
```

RCCL 在每次读取参数时：**先读配置文件，再读环境变量，环境变量优先**。

于是：

- 环境被裁剪的进程（vLLM worker）→ 从 `/etc/rccl.conf` 拿到拓扑 ✅
- 环境正常的进程（ComfyUI / SGLang）→ 环境变量覆盖，各自指定自己的拓扑 ✅
- 单卡程序 → 不受影响（只有一张卡时不涉及 peer 判定）

**这是唯一不依赖"环境能不能传下去"的机制。**

### 4.2 内容

```ini
# /etc/rccl.conf —— 由 scripts/install-rccl-conf.sh 生成
NCCL_TOPO_FILE=/etc/p2p/topo-pxb.xml
NCCL_P2P_DISABLE=0
NCCL_P2P_LEVEL=PXB
```

### 4.3 两种拓扑形状的冲突（重要）

| 启动形态 | 需要的拓扑 | 谁属于这一类 |
|---|---|---|
| 单进程可见两张卡（`dev=0/1`） | `/etc/p2p/topo-pxb.xml` | vLLM、SGLang |
| 每进程只可见一张卡（`dev=0/0`） | `/etc/p2p/topo-pxb-single.xml` | ComfyUI TP2 双实例 |

全局 conf 只能写一种。默认写**双卡可见版**，因为：

- 环境变量优先于 conf；
- ComfyUI TP2 的启动器已经在自己 env 里显式指定了单卡可见版拓扑（实测其进程 env 中存在指向 `p2p_topology.xml` 的 `NCCL_TOPO_FILE`），不会被 conf 覆盖。

若某个启动器没显式指定，混用会报 `Ring 0: Asymmetric link!` —— 见
[comfyui-tp2.md](comfyui-tp2.md)。判断口径：**该进程看到几张卡**，就选对应的拓扑文件。

### 4.4 安装与回滚

```bash
sudo bash scripts/install-rccl-conf.sh              # 安装（幂等，自动备份）
sudo bash scripts/install-rccl-conf.sh --single     # 改为单卡可见版拓扑
sudo bash scripts/install-rccl-conf.sh --rollback   # 还原
```

安装后**必须重启对应引擎**才生效（RCCL 在进程内缓存参数）。

### 4.5 验证

```bash
bash scripts/p2p-verify-engines.sh
```

输出三类判定：

1. 每个进程 `NCCL_*` 是否可见；
2. `/etc/rccl.conf` 是否存在且路径有效；
3. 该进程该用哪一版拓扑（按可见卡数推断）。

要拿运行期铁证，给引擎加 `NCCL_DEBUG=INFO NCCL_DEBUG_SUBSYS=INIT`，启动日志里应出现：

```
Check P2P Type isAllDirectP2p 1 directMode 0
Channel 00/0 : 0[5000] -> 1[8000] via P2P/IPC
```

出现 `via SHM/direct/direct` 即仍未生效。

### 4.6 唯一能破坏它的东西

**任何启动脚本里 `export NCCL_P2P_DISABLE=1`。** 环境变量优先级高于配置文件，写进 conf 的 `0` 会被覆盖。此前那个 vLLM 实例就是带着 `NCCL_P2P_DISABLE=1` 启动的。

检查口径：

```bash
grep -rn "NCCL_P2P_DISABLE=1" ~/.bashrc /etc/profile.d/ /path/to/launcher/*.sh
```

## 五、排查口径（三条）

1. **看真正干活的进程，不看启动脚本。** `pgrep -f "VLLM::|sglang::"` 之后逐个查 `/proc/<pid>/environ` 的 `NCCL_` 计数。
2. **`NCCL_` 计数为 0 就一定是 SHM**，不管 driver 里看着多正确。
3. **先看 `/etc/rccl.conf` 在不在**。不在，就说明只靠环境变量，任何"重建 env"的框架都可能把它弄丢。

## 五、P2P 生效下的并发表现（SGLang TP=2 实测）

条件：`qwen38-27b`（Qwen3.8-27B-AWQ-INT4）、`--tp-size 2 --disable-custom-all-reduce --attention-backend triton --mem-fraction-static 0.85`、P2P 走 `via P2P/IPC`、`max_tokens=256`、temperature=0、每级并发 ×4 轮。

| 并发 | 请求数 | 成功 | 总吞吐 (tok/s) | 单请求 (tok/s) | TTFT P50 | TTFT P95 | 端到端 P50 | 端到端 P95 | GPU 双卡 |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 4 | 4/4 | 17.7 | 17.7 | 590 ms | 2167 ms | 14.1 s | 15.6 s | 97.0% / 96.9% |
| 2 | 8 | 8/8 | 33.8 | 16.9 | 1074 ms | 1180 ms | 15.2 s | 15.2 s | 99.5% / 99.5% |
| 4 | 16 | 16/16 | 61.3 | 15.3 | 2063 ms | 2694 ms | 16.6 s | 17.2 s | 98.8% / 98.8% |
| **8** | **32** | **32/32** | **106.5** | **13.3** | **4070 ms** | **4148 ms** | **19.2 s** | **19.3 s** | **99.7% / 99.7%** |

### 5.1 扩展效率

| 区间 | 吞吐倍数 | 扩展效率 |
|---|---|---|
| 1 → 2 | 1.91× | 95.5% |
| 1 → 4 | 3.46× | 86.6% |
| 1 → 8 | **6.02×** | **75.2%** |

8 并发拿到单请求 6 倍的吞吐，剩下 25% 的损失来自共享算力与 attention KV 读取，不是通信。

### 5.2 两个拐点

- **TTFT 线性翻倍**：590 → 1074 → 2063 → 4070 ms，每翻一倍并发就翻一倍。瓶颈在 `chunked_prefill_size=2048`：8 条请求的 prefill 要排 4 批。要提高首字速度，先调这个参数，不是调 P2P。
- **单请求速率 -24.9%**：17.7 → 13.3 tok/s。这是 TP 双卡共享带宽的正常摊薄，8 条流同时跑时总量仍是单条的 6 倍。

### 5.3 关于 P2P 的判断

两卡 GPU 利用率始终 96.9%~99.7% 且**几乎完全对齐**（差值 ≤ 0.1 个百分点）。如果 TP 的 `all_reduce` 卡在 SHM 上，rank1 会周期性等 rank0，出现明显的利用率锯齿与差值。实测没有 —— 与 §3.1 的 `via P2P/IPC` 互相印证。

`max_running_requests=25`、`max_total_num_tokens=200487`，8 并发远未触顶，服务端没有排队拒绝。

### 5.4 复现

```bash
/home/jay/sglang-venv/bin/python scripts/bench-sglang-concurrency.py 1,2,4,8 4
```

## 六、这次没做到的

- vLLM 侧"哪一行代码重建了 env"未定位到具体行号——只坐实了**结果**（进程 env 无 `NCCL_TOPO_FILE`）与**排除项**（不是 Python spawn 的通用行为）。修复方案不依赖这个定位；
- `/etc/rccl.conf` 生效前后的 **allreduce 带宽数字对比**（本次只拿到 `via P2P/IPC` 的通道证据，没跑吞吐基准）。

## 七、从 SGLang / vLLM 的 TP2 通信栈反推：本机补丁能不能承载这些帖子

> 2026-11-08。样本：vLLM **0.32.0**（`/home/jay/vllm-venv`）、SGLang gfx1100 fork（`/home/jay/sglang-gfx1100`，editable 安装），两者均为 torch `2.13.0+rocm7.2` / RCCL `2.27.7`；内核已升到 `7.0.0-42-generic`，DKMS `p2p-force/1.0` 已随内核重建。

### 7.1 TP2 不是一条路，而是四条

两个框架的 TP2 都按「小张量走 IPC 自定义 allreduce、大张量走 RCCL」分层，但启用条件不同。逐条查源码后，本机实际只有**第一条**在跑：

| # | 通信路径 | 谁在用 | 是否需要真 P2P | 本机事实（代码依据） |
|---|---|---|---|---|
| 1 | **RCCL ring/tree allreduce** | vLLM、SGLang 的兜底，也是当前实测主路径 | 需要；没有就走 SHM（主机内存中转） | `/etc/rccl.conf` 提供拓扑；实测 `via P2P/IPC` ×4、16 MB allreduce **5.00 GB/s** |
| 2 | vLLM CustomAllreduce（HIP IPC） | vLLM TP=2 **默认启用** | 需要（IPC peer 映射） | `_ENABLE_CUSTOM_ALL_REDUCE=True`；本机 `meta_size()` 可用 → `custom_ar=True`；ROCm 分支**跳过** P2P 探测（`custom_all_reduce.py` §281-291，注释写「AMD 上 XGMI 之间 P2P 恒开」） |
| 3 | vLLM QuickAllReduce | 仅 MI300 | 不适用 | `_rocm_arch_available()` 只认 `gfx94/gfx95` → gfx1100 自动 disabled |
| 4 | AITER Custom AR | 需显式 `VLLM_ROCM_USE_AITER_CUSTOM_AR` + AITER 支持 | 不适用 | 本机未启用 |
| 5 | SGLang CustomAllreduce | 默认走 NVLink/amdsmi 探测；`SGLANG_RDNA_CUSTOM_AR=1` 才是 fork 的 PCIe IPC 版 | 需要 | 本机 amdsmi 不可用 → 默认 disabled；启动器显式 `--disable-custom-all-reduce`；`custom_all_reduce.py` §99-111 |
| 6 | SGLang QuickAllReduce | 仅 gfx94/gfx95 | 不适用 | `qr_rocm_arch_available()` → gfx1100 disabled |
| 7 | Strata peer 直拷 | Strata 双卡层切分 | 直接依赖内核 peer access | 不走 RCCL，自带 memcmp 自检（见 §3.2） |

反推的关键结论只有一句：**两个框架的 TP2 都把「AMD 卡之间必有 P2P」当公理**——vLLM 连检查都不做，SGLang 的默认路径直接把 custom AR 关掉。本机是 PCIe 而非 XGMI，所以这条公理要么由内核补丁兜住，要么就必须显式绕开。

### 7.2 逐帖判定

| 帖子 | 方案形态 | 本机能否执行 | 与本补丁的关系 | 特别设置 |
|---|---|---|---|---|
| [#2525](https://lcz.me/topic/2525) TP2 的坑（PCH） | RCCL TP2 | ✅ 能。该帖的 401 故障链在本机不成立（双卡不在 PCH 下、根端口 AtomicOps 全 +、交换芯片 Routing+，见 `report.md` §2.1） | **无关**。补丁只去掉 p2pdma 白名单这道软件门，修不了 PCH 的 AtomicOp 缺失——别把 X99 补丁当 PCH 平台的解药 | `/etc/rccl.conf` 必须在；启动环境不得有 `NCCL_P2P_DISABLE=1`；用 `NCCL_DEBUG=INFO NCCL_DEBUG_SUBSYS=INIT` 确认 `via P2P/IPC` 而非 `via SHM` |
| [#2599](https://lcz.me/topic/2599) 双 R9700 / Arrow Lake P2P | 内核强开 p2pdma + 伪造 PXB 拓扑 | ✅ 能，本仓库即该方案的 X99 移植；2026-11-08 在 `7.0.0-42` 复测通过：`canAccessPeer` 双向 True、`isAllDirectP2p 1`、`via P2P/IPC` ×4、5.00 GB/s、`bad=0` | 同源 | BIOS 四项（VT-d / Above4G / ReBAR / ACS off）+ Secure Boot off；**每次内核升级后确认 DKMS 已重建**；拓扑 BDF 必须与实机一致（`gen-topo.sh`）。帖子是 Gen5 平台，本机 Gen3 x8（理论 7.88 GB/s），5.0 GB/s 已接近本机上限，**不能拿帖子的带宽当验收线** |
| [#2132](https://lcz.me/topic/2132) gfx1100 SGLang 魔改 | `--tp-size 2` + 该 fork 的 RDNA kernel | ✅ 能；补丁与 fork 不冲突 | 兼容，但要选对 custom AR 开关（见 7.1 第 5 行） | `--disable-custom-all-reduce`（启动器已带）；`--attention-backend triton`；`--mem-fraction-static 0.79`（DFlash2 要留 4 GB 给 BF16 draft）。想启用 fork 的 `SGLANG_RDNA_CUSTOM_AR=1` 时，必须同时满足：内核 peer access on、双卡可见拓扑、每进程只绑一张卡——缺一即 peer 读到 0 或建图报错；当前该扩展未安装，保持关闭 |
| [#24728](https://lcz.me/post/24728) Strata DP2 双单卡 replicas | 两个独立单卡实例 | ✅ 能，但**不用 TP2、不走 RCCL** | **无关**：P2P 既不加速也不阻碍 | 无。不要为它把 `/etc/rccl.conf` 换成单卡拓扑——单卡进程不涉及 peer 判定，conf 对它是空操作 |

### 7.3 vLLM TP2 的两条路线（唯一需要做选择的地方）

| 路线 | 启动参数 | 依赖 | 验收口径 |
|---|---|---|---|
| A · 保留 custom AR（默认） | 不加 `--disable-custom-all-reduce` | **强依赖内核补丁**：ROCm 分支跳过 P2P 探测，IPC peer 映射失败时不会优雅回退 | 启动无 IPC 报错；双卡利用率对齐（差 ≤ 0.1 个百分点）；同 prompt 输出一致；`via P2P/IPC` 仍出现 |
| B · 收敛到 RCCL（保守） | `--disable-custom-all-reduce` | 只依赖 `/etc/rccl.conf` + 内核补丁 | 与 SGLang 当前配置同口径，已有完整的 1/2/4/8 并发数据（§5） |

**建议**：先按 B 跑（可复现、有基线），确认 `via P2P/IPC` 后再试 A；A 的收益只在小张量 allreduce，风险是 peer 映射失败时没有探测兜底。

### 7.4 会静默失效的三件事

1. **`NCCL_P2P_DISABLE=1` 残留**（shell / systemd / 启动器）——环境变量优先于 `/etc/rccl.conf`，P2P 直接关掉；
2. **拓扑形状错**——单进程双卡可见（vLLM/SGLang）用 `topo-pxb.xml`，每进程单卡可见（ComfyUI）用 `topo-pxb-single.xml`，混用报 `Ring 0: Asymmetric link!`；
3. **内核升级后 DKMS 没重建**——`canAccessPeer` 变 False，但引擎照常启动（回落 SHM），只有对比日志/带宽才发现变慢。

### 7.5 复现（本次实测，`7.0.0-42-generic`）

```bash
lsmod | grep p2p_force
TORCHRUN=/home/jay/sglang-venv/bin/torchrun bash scripts/p2p-preflight.sh
```

输出要点：

```
[OK]   RCCL 已走 P2P/IPC
[probe] canAccessPeer 0->1=True 1->0=True
Check P2P Type isAllDirectP2p 1 directMode 0
Channel 00/0 : 0[5000] -> 1[8000] via P2P/IPC
Channel 01/0 : 1[8000] -> 0[5000] via P2P/IPC
[probe] allreduce 16MB: 3352.2 us/iter, 5.00 GB/s, bad=0
```
