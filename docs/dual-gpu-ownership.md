# 双卡占用权：常驻推理服务与 TP 作业共存

两台 RX 7900 XTX（24.5 GB/卡）既要跑常驻的层切分大模型服务，又要跑 ComfyUI TP2 / vLLM /
SGLang 的张量并行业务。本文记录两者的互斥规则、掉线根因与参考实现
（[`scripts/gpu-owner.sh`](../scripts/gpu-owner.sh)）。

## 为什么只能互斥，不能共存

| 负载 | 每卡峰值显存 | 形态 |
| --- | --- | --- |
| ComfyUI TP2（MiniMax-H3 int8/w4a8） | 23.87 GB | 双卡张量并行，每进程只见一张卡 |
| 常驻层切分 LLM 服务（双卡） | ≈23 GB | 双卡层切分，每 token 跨卡传隐状态 |
| 单卡可用上限 | 24.5 GB | — |

两个 23 GB 级别的负载在同一条卡上物理上放不下；把常驻服务压到 4 GB/卡也仍容不下 24 GB 的
TP rank。结论：**冲突的本质是整卡占用权，不是“谁多占了几十兆”**。缩小常驻显存只能换来更快的
切换与更低的 OOM 风险，换不来共存；本机唯一可行的并行形态是“单卡常驻 + 另一卡单卡任务”。

## 掉线的根因

1. 所有切到工作态的入口（快捷方式、工作台、`stop-all`）都只做 `stop/exit`，没有“谁停了、
   什么时候恢复”的记录。
2. 服务单元是 `Restart=always`，但它只对**异常退出**生效；`systemctl stop` 是干净退出（exit 0），
   所以停完永远不会自己回来 —— 表现为“掉线”。
3. 反过来，显存不足导致启动失败时，`Restart=always` + `StartLimitIntervalSec=0` 会无限空转
   （实测 134 秒内重启 124 次）。
4. 引擎脚本启动前不检查显存/服务占用，只能靠人工先停服务，跑完无人拉起。

## 机制

单一事实来源：`~/.gpu-owner`（`owner=work|daily`、`job`、`pid`、`since`、`boot`、
`restore_running`、`restore_mode`、`ttl`），配 `flock` + 临时文件 rename 原子更新；另一个空文件
`.worklock` 供 systemd 守卫判断。

| 环节 | 行为 |
| --- | --- |
| `acquire <job>` | 检查是否已有存活的工作态 → 记录服务前态（是否在跑、单/双卡）→ 停服务（保留 `/dev/shm` arena 以便快速恢复）→ 等双卡显存 <1500 MiB（120 s）→ 校验可用内存 → 发占用权 |
| `holder <pid>` | 启动引擎后写入真实 PID；引擎崩溃即被看门狗发现 |
| `release` | 清状态 → 等显存回落（90 s，覆盖 rank1 残留）→ 启动服务并等 `/health`；失败重试一次，仍失败则登记 `restore_pending` |
| 看门狗（30 s） | 持有者进程消失（60 s 启动宽限）或超过 TTL（12 h）→ 自动 `release`；`restore_pending` 存在时持续重试恢复 |
| 守卫（`pre-start`/`ExecStartPre`） | 工作态任务存活时拒绝启动/重启/切换服务；开机时 `boot_id` 不一致视为陈旧状态并清理 |
| 用户显式停服 | `strata-ctl stop/exit` 记录“用户停服”，取消自动恢复，避免被看门狗反拉 |
| 重启策略 | `Restart=on-failure`、`RestartSec=30`、60 s 内最多 3 次，消除无限空转 |
| 内存兜底 | 32 GB zram（zstd，priority 100）；内存耗尽不再直接触发全局 OOM 杀进程 |

## 接线方式

- 引擎 `start`：先 `acquire <job>`，spawn 后立刻 `holder <engine-pid>`；启动失败要 `release` 回滚。
- 引擎 `stop`：`release`，自动把常驻服务拉回日常态。
- 内部切换（同脚本先停再起）与“清空全部”（`stop-all.sh`）：`release --no-restore`，避免
  停→起→再停的来回抖动。
- 预设/工作台：不要再自己 `stop` 常驻服务，交给目标引擎的 `acquire` 统一负责。

## 实测

| 验证项 | 结果 |
| --- | --- |
| `acquire` 挂起服务 | 通过，双卡显存回落至 26 MiB |
| 工作态下启动服务 | 被拒绝（`工作态占用中`，退出码非 0） |
| 持有者进程消失 | 看门狗 91 s 触发并恢复成功 |
| `release` 恢复 | 成功，`/health` 返回 `ok`，模型已加载 |
| 回归 | 挂起→拒绝→恢复全链路通过，占用权回到 `daily` |

## 案例（2026-11-07）：节点子进程挡住 acquire

ComfyUI TP 作业已停、常驻服务已挂起，`acquire` 仍连续两次失败，报
`显存未回落到 1500 MiB 以下：card0 9733/24560MiB card2 9675/24560MiB`。
此时没有任何 ComfyUI 主进程存活，`nvidia-smi` 也查不到 compute app——但 amdgpu 的
`mem_info_vram_used` 实打实各占 9.7 GB。

根因：`ComfyUI_Qwen_H3_Prompt` 节点自行 spawn 的 `llama-serve` 后端进程在主进程退出后
**没有跟着退出**，成了孤儿，双卡各攥着 ~9.7 GB。定位手段是按文件句柄反查持有者：

```bash
for p in /proc/[0-9]*; do
  ls -l $p/fd 2>/dev/null | grep -qE 'drm|dma-buf|kfd' \
    && echo "${p#/proc/} $(tr '\0' ' ' < $p/cmdline)"
done
# → 292464 .../ComfyUI_Qwen_H3_Prompt/runtime/.../llama-serve
kill 292464   # 两卡随即回落到 48 MiB，acquire 通过
```

对占用权机制的三点修正/提示：

1. **停 TP 作业要停进程组**，或 `release`/停止入口先按上述句柄反查清掉节点 spawn 的
   长驻子进程——否则 `wait_vram_free` 会一直等到超时，失败原因看起来像「服务没停干净」。
2. **`nvidia-smi` 不是本机判据**（ROCm 栈），显存是否释放以
   `/sys/class/drm/card*/device/mem_info_vram_used` 为准，这正是 `acquire` 读的口径。
3. 该 ComfyUI 实例是绕过 `acquire` 手动启动的，因此它的子进程**不在 holder 追踪范围内**：
   占用权机制只对「先 acquire 再启动」的正规接线有效，旁路启动的负载要人工负责收尾。

## 与 topo 补丁的适用范围

`NCCL_TOPO_FILE` 只被 RCCL 读取，因此本仓库的拓扑修复/rank 绑定修复**只对张量并行 + RCCL
collective 的负载有收益**（ComfyUI TP2、vLLM、SGLang）。层切分引擎（含本机的 Strata）不读
该变量、不走 all_reduce，收益为零；单流 decode 上 TP 的逐层 all_reduce 反而更慢。

所以：**不要指望“缩小常驻显存”让常驻服务与 TP2 共存**，正确做法是占用权互斥 + 任务结束自动恢复。
