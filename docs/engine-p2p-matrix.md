# 引擎侧 P2P 生效矩阵：为什么 vLLM 里 P2P 会失效，以及怎么让它永远生效

> 2026-11-07 实测。样本：vLLM TP=2（Qwen3.8-27B-AWQ-INT4，`--port 30012`）+ ComfyUI TP2 双实例。
> 本文只讨论**第三层（运行时环境变量）**，内核层与拓扑层见 [report.md](report.md)。

## 一、结论先给

| 引擎 / 形态 | 每进程可见卡 | P2P 是否生效 | 证据 |
|---|---|---|---|
| ComfyUI TP2（双进程，各 `HIP_VISIBLE_DEVICES=$r`） | 1 张 | ✅ 生效 | 进程 env 内 `NCCL_TOPO_FILE` 指向单卡可见版拓扑 |
| **vLLM TP=2（单进程双卡可见）** | 2 张 | ❌ **失效** | 真正建通信子的 worker 进程 env 里 `NCCL_*` 计数为 **0** |
| SGLang TP=2（单进程双卡可见） | 2 张 | ⚠️ 机制上成立，待实测 | 标准 `mp.Process` spawn，无 env 白名单（源码证据） |
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

## 三、另外两个引擎

### 3.1 SGLang：机制上没问题

- `sglang.launch_server` 用标准 `mp.Process` + `spawn`，**没有** env 白名单；
- 启动脚本 `sglang-tp.sh` 的 tp2 分支不设 `HIP_VISIBLE_DEVICES`（双卡可见），与 `topo-pxb.xml` 的 `dev=0/1` 一致；
- 因此 `NCCL_*` 会一路继承到 scheduler/tp worker。

待办：在两张卡空闲时跑一次 `sglang-tp.sh start tp2` 并 `grep isAllDirectP2p` 取运行期实证（本次实测时两卡被 vLLM 占满，未做）。

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
NCCL_TOPO_FILE set by environment to /etc/p2p/topo-pxb.xml
isAllDirectP2p 1
via P2P/IPC
```

出现 `via SHM/direct/direct` 即仍未生效。

## 五、排查口径（三条）

1. **看真正干活的进程，不看启动脚本。** `pgrep -f "VLLM::|sglang::"` 之后逐个查 `/proc/<pid>/environ` 的 `NCCL_` 计数。
2. **`NCCL_` 计数为 0 就一定是 SHM**，不管 driver 里看着多正确。
3. **先看 `/etc/rccl.conf` 在不在**。不在，就说明只靠环境变量，任何"重建 env"的框架都可能把它弄丢。

## 六、这次没做到的

- SGLang 的运行期实证（两卡被占满，未抢卡实测）；
- vLLM 侧"哪一行代码重建了 env"未定位到具体行号——只坐实了**结果**（进程 env 无 `NCCL_*`）与**排除项**（不是 Python spawn 的通用行为）。修复方案不依赖这个定位；
- `/etc/rccl.conf` 生效后的 vLLM 带宽复测（需停掉在跑的任务）。
