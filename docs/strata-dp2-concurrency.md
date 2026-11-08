# Strata DP2 双单卡 replicas 并发实测（参考 lcz.me/post/24728）

帖子方案：不用 TP2/layer split，用 Strata 自带 `replicas` 机制——每卡一个独立模型副本（独立 engine、KV、MTP、会话），单端口，请求按「会话回原卡、否则最闲」路由，双流聚合互不干扰。帖子成绩：单流 83.85 tok/s，双流聚合 159.7–170.8 tok/s。

本机（Xeon E5-2696 v4 22c44t + 2×7900 XTX，Strata v0.1.47）复刻结果如下。

## 一、实测结果

| 指标 | 帖子（EPYC 7452） | 本机实测 | 差距 |
|---|---|---|---|
| 单流（稳定档） | 83.83–84.03 tok/s | **62.8–74.1 tok/s，均值 67.2** | −20% |
| 双流聚合 ×4 | 159.7–170.8 tok/s | **90.3–97.7 tok/s，均值 92.9** | −43% |
| 双流每流 | ~80 tok/s | ~46 tok/s | −42% |
| MTP 草稿接受率 | — | **69.4%**（1984/2859） | — |
| OOM/崩溃 | — | 修复后 0 次（修复前双流必崩） | — |

方法：SSE 流式、`stream_options.include_usage`、服务端 `completion_tokens` 计数、温度 0、300 tokens、先双卡各预热一次；聚合 = 两流总 token ÷ 墙钟。副本路由经 `/metrics` 确认均衡（routed 8 : 7）。

### 为什么比帖子低（差距归因）

Strata 的 native 专家路径是**主机内存流式计算**（专家权重加载进 RAM，GPU 只做 reduction）——这条路径吃 CPU 与内存带宽：

1. **CPU 代差 + 无 AVX-512**：引擎日志明确 `this CPU has no AVX-512: the expert kernels run on AVX-2`。E5-2696 v4 是 Broadwell（2.2 GHz 基频），帖子是 EPYC 7452 Zen2。→ 解释单流 −20%。
2. **内存带宽是双流的硬顶**：本机 DDR4 四通道（Broadwell-EP ≈ 77 GB/s），帖子 EPYC 八通道（≈ 205 GB/s）。单流已接近带宽上限（67），双副本共享同一条内存总线 → 每流掉到 46、聚合 92 而非 134。帖子双流不掉速（2×80），差在这里。→ 解释双流 −43%。

结论：**方案本身在本机成立且稳定**（路由均衡、无崩溃、聚合 92.9 ≈ 单流 ×1.38），收益上限受制于本机 CPU/内存带宽；这台机器的 Strata 并发天花板就是 ~90–100 tok/s 聚合。

## 二、踩坑记录（复刻必读）

### 1. 共享 expert arena 不要手建

`/dev/shm/strata-shared-arena.bin` 必须由引擎创建——它带 pack 哈希头。手工 `truncate` 出的空文件（无论 157 MB 还是精确的 50294992896 字节）都会被拒：

- 尺寸不对：`could not be reserved (50294988800 B): ... is X B, expected 50294992896 B`
- 尺寸对但无哈希头：`shared arena ... has an incompatible or missin[g]`

**正确做法：删掉文件直接启动**，引擎自建（~46.8 GiB tmpfs，需 /dev/shm ≥ 50 GB；本机 63 GB 够）。

### 2. `--vram-reserve-mib 256` 不够，双流必崩

首次压测双流时 replica 1 崩溃：

```
verify: instantiate: out of memory
→ [strata] replica 1 had stopped; starting it again（54s 停顿 = 重建 46.84 GiB）
```

根因：expert-cache `auto` 把显存吃到只剩 146 MiB，双流期间 verify 窗口 CUDA graph **懒捕获**时没余量。**修复：`--vram-reserve-mib` 256 → 1536**（expert cache 自动缩水 1.3 GB），修复后 4/4 轮零崩溃。

### 3. 双流必须用不同提示词（会话路由陷阱）

路由规则是「同一会话回原卡」。两个并发流用**完全相同**的提示词时，会话键相同 → **都进同一副本排队**，聚合只有 46–60 tok/s。改用不同提示词后立即恢复路由均衡（routed 8:7），聚合 92.9。

### 4. profile 路径指向已拔的 USB

本机 `strata-iq3_s-dp2.json` 的 native/pack 路径还停在 `/media/jay/D80FB5BFFA0F57B7/...`，实际文件在 `/mnt/llm/...`（NVMe，/mnt/llm 即根分区）。已批量替换并同步到 `strata-patch/`。

### 5. pkill 自匹配

`pkill -f "strata.py serve"` 会匹配到执行命令本身的命令行（bash -c 全文含该串）把 shell 自杀。**用括号正则**：`pgrep -f "strata[.]py serve"`、`pgrep -f "build-hip[/]strata"`。

## 三、启动方式与观测

```bash
cd /home/jay/strata
# 起（独立端口，不影响 systemd 的 8080 layer-split 模式）
setsid nohup .venv/bin/python strata.py serve \
  --profile strata-iq3_s-dp2.json --host 127.0.0.1 --port 8082 \
  > strata-dp2-8082.log 2>&1 < /dev/null &
# 就绪判定
curl -s http://127.0.0.1:8082/health
# 副本路由/槽位/接受率
curl -s http://127.0.0.1:8082/metrics | python3 -m json.tool
#   live.replicas → [{replica, alive, running, routed, batch}, ...]
#   totals → drafts_offered/drafts_accepted
```

启动到就绪约 **78 s**（含 55 GB 专家加载进 RAM + GEMM 预热），进程 RSS 每副本 51.9 GB，显存每卡 23.4 GB。

## 四、与 TP2 的分工（同一台机）

| | Strata DP2（本篇） | SGLang TP=2 |
|---|---|---|
| 并发模式 | 双单卡副本，无卡间通信 | 张量并行，all_reduce（P2P 已验证 via P2P/IPC） |
| 本机峰值 | 单流 67 / 双流聚合 93 | 单流 28（无投机）/ 并发 147–152 |
| 适合 | 单流交互、两条独立会话 | 多路并发批量、追求总吞吐 |
| 显存 | 每卡 23.4 GB 满载（无余） | 每卡 20.6 GB |

两者互斥占卡（gpu-mode 占用权机制管理），按场景二选一。

## 五、回退决策（2026-11-08）：已停用 DP2，回到 SGLang TP2 + DFlash2

实测对比后按「多任务并发为主」的使用场景做了回退：

| | Strata DP2 | SGLang TP2 + DFlash2（回退后） |
|---|---|---|
| 单流 | **67.2** | 49.5–52.2 |
| 8 并发聚合 | **93 封顶，槽位仅 2**（第 3 个任务起排队） | **147–152，8 路合批** |
| 每任务体感（多任务） | 每流掉到 46 + 排队 | 合批摊薄，明显更快 |

判定：DP2 单流快 36%，但并发总吞吐低 40%+ 且槽位只有 2，整体没以前好 → 回退。回退操作：`pkill -f 'strata[.]py serve'`（含 `build-hip[/]strata`）停 DP2，再 `MODEL_27B=/mnt/llm/sglang/models/Qwen3.8-27B-abliterated-AWQ-INT4 bash sglang-tp.sh start tp2`（脚本默认 /mnt/d 路径已失效，须用环境变量指回 /mnt/llm）。回退后验证：DFlash2 生效（`speculative_algorithm=DFLASH`、mem_fraction 0.79）、单流 52.2 tok/s、生成正常；P2P 仍由 `/etc/rccl.conf` 系统级兜底，无需额外处理。

DP2 方案保留在上文，仅当需要「单流 67 tok/s 上限」或「两条完全独立会话」时再临时切换。
