# 默认 TP=2 + P2P 策略（单卡必须显式指定）

> 立于 2026-11-07 的一次真实故障样本。策略闸实现见
> [`scripts/tp2-guard.sh`](../scripts/tp2-guard.sh)，双卡占用权见
> [`docs/dual-gpu-ownership.md`](dual-gpu-ownership.md)，TP2 接线见
> [`docs/comfyui-tp2.md`](comfyui-tp2.md)。

## 策略声明

1. **本机一切负载的默认形态是「双卡」**：影音视频生成与 ComfyUI 图像生成 → **TP=2 双实例 + P2P**；
   vLLM / SGLang → TP 双实例；常驻 LLM（Strata）→ 双卡层切分（其本征形态即双卡）。
2. **单卡运行属于定制要求，必须由本人显式指定**：统一开关 `TP_ALLOW_SINGLE=1`（ComfyUI 侧
   对应 `COMFY_TP_ALLOW_SINGLE=1`）。未显式指定而以单卡形态入口启动 → **弹提示框，然后静默改道，
   自动以 TP=2 双实例 + P2P 启动**（不问、不阻塞、不默默降速）。
3. 策略闸尽量下沉到启动器（底层接线），不依赖人记得选对脚本。

## 背景：这次故障是什么样本

2026-11-07：用户观察到「TP=2 实例在跑，TP=1 实例不加速」。以 ComfyUI-AMD 的 8188 实例为样本，
诊断结论：**它从头到尾就没进过 TP**——

| 证据 | 值 |
| --- | --- |
| 启动方式 | `main.py --lowvram --port 8188`（AutoLaunch 脚本），无任何 `COMFY_TP_*` |
| 日志 | `[tp2] world=1 rank=0 enrolled`（`_init_pg()` 首行 `TP_WORLD<=1` 直接早退，所有钩子不安装） |
| 实测速度 | 36 ~ 60 s/it（单卡 lowvram），对比 TP2 的 7.6 s/step 慢 **5.2 ~ 7.9 倍** |
| 双卡可见 | `HIP_VISIBLE_DEVICES=0,1` —— 可见 ≠ TP，只是必要条件之一 |

## 底层强制为什么只能是「拒绝」或「改道」，不能是「设值」

TP=2 是**双进程模型**：两个进程各绑一卡，靠 `COMFY_TP_WORLD/RANK` + `MASTER_ADDR/PORT`
做 NCCL rendezvous。底层若单进程强制设 `COMFY_TP_WORLD=2`，rank0 会等待永远不来的 rank1，
**挂死 30 分钟超时**。因此「强制」只有两种正确形态：

- **fail-fast**：单卡形态启动直接退出并打印指引（评估后未采用：入口直接不可用，体验过硬）；
- **改道**：把单卡启动自动重定向到双实例启动器（**现行方案**）：先弹提示框告知
  「已按默认策略改道 TP=2 + P2P」，再 `exec run_tp.sh 2 …` 静默启动；单卡定制走
  `TP_ALLOW_SINGLE=1` 放行。

## 入口清单与默认状态

| 入口 | 默认形态 | 策略闸 |
| --- | --- | --- |
| 工作台（ai-workbench UI/API） | ✅ TP 引擎（`comfyui-tp2.sh` / `vllm-tp.sh` / `sglang-tp.sh`） | 已是 TP 默认，无需闸 |
| `tp2/run_tp.sh 2` / `comfyui-tp2.sh start` | ✅ TP=2 + P2P + 占用权 acquire | 正规路径本身 |
| `AutoLaunch_ComfyUI.sh`（ComfyUI-AMD，bug 样本） | ⚠️ 已接闸：默认提示框 + 静默改道 `run_tp.sh 2`；`TP_ALLOW_SINGLE=1` 放行原单卡路径 | `tp2-guard.sh` |
| Strata 常驻服务 | ✅ 双卡层切分（`shortcut-switch.sh single/dual` 是既有显式开关） | 不适用（见下表） |
| 手动 `python main.py`（绕过启动器） | ❌ 无法拦（策略闸管不到裸命令） | 靠排查口径兜底 |

## 按负载的默认表

| 负载 | 默认 | 单卡例外（须本人指定） |
| --- | --- | --- |
| 影音视频生成（ComfyUI · H3 等） | **强制 TP=2 + P2P** | `TP_ALLOW_SINGLE=1` |
| ComfyUI 图像生成 | **强制 TP=2 + P2P** | 同上 |
| LLM · vLLM / SGLang | TP 双实例（现状即如此） | 同上 |
| LLM · Strata 常驻 | 双卡层切分，**禁止改成 TP**：本机 A/B 实测 TP 化 decode +440.8%、prefill128 +187.2%（Strata 是层间切分，无 `all_reduce` 作用对象） | `shortcut-switch.sh single`（既有开关） |

## 失效边界（闸什么时候不拦）

| 条件 | 行为 |
| --- | --- |
| `TP_ALLOW_SINGLE=1` | 放行单卡，日志打印「按用户显式指定」 |
| 守卫文件缺失 | 仍然硬失败（策略闸不可被环境问题绕过），提示恢复路径 |
| 绕过启动器直接 `python main.py` | 拦不住；靠 `grep '\[tp2\]' 日志` + `pgrep -af main.py`（双进程）人工排查 |
| 工作台入口 | 本就只挂 TP 引擎，不经过此闸 |
| ComfyUI 节点层（`comfyui-tp2/__init__.py`） | 未加闸（本次范围外）；`world=1` 时按设计早退走原生路径 |

## 排查口径（三行）

1. `grep '\[tp2\]' r0.log r1.log` —— `world=1` 即没进 TP；`world=2` 且 rank=0/1 各一条才成立。
2. `pgrep -af 'main.py'` —— 必须 2 个进程、各自 `HIP_VISIBLE_DEVICES` 绑不同卡。
3. `acquire` 失败先读 `/sys/class/drm/card*/device/mem_info_vram_used`，再按
   `/proc/*/fd` 反查 `drm|kfd` 句柄找残留子进程（案例见 `dual-gpu-ownership.md`）。
