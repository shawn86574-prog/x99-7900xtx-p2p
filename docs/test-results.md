# 本次实测结果与判据修正

> 2026-10-29/30。被测对象是仓库里这套改动（`kernel/p2p_force.c` + `topo/fake_topo_p2p.xml` + `scripts/p2p-env.sh`）。
> 所有数字都来自本机实测，没有外推；性能数据由内部基准脚本产生，脚本本身未随仓库发布。

---

## 1. 平台

| 项 | 值 |
|---|---|
| CPU | Intel Xeon E5-2696 v4 @ 2.20 GHz（Broadwell-EP，1 路，22 逻辑核） |
| 主板 / 芯片组 | X99 / C610，host bridge `8086:6f00` |
| 内存 | 128 GB DDR4 ECC |
| 计算卡 | 2 × Radeon RX 7900 XTX 24 GB（`1002:744c`，05:00.0 / 08:00.0） |
| 亮机卡 | GeForce GTX 750 Ti（`10de:1380`） |
| 内核 | `7.0.0-38-generic`（`CONFIG_KRETPROBES=y`、`CONFIG_PCI_P2PDMA=y`） |
| IOMMU | translated；两张卡分别在 group 52 / 56，DMAR 主机地址宽度 46 位 |
| GPU BAR | `Region 0` 32 GB，64-bit prefetchable，落在 `0x383000000000`（Above 4G + ReBAR 生效） |
| ACS | 全总线 0 处 ACS 能力（未启用重定向） |
| 启动参数 | `pcie_aspm=off`（ASPM 关闭） |
| GPU 架构 | `gfx1100` × 2（`gfx_target_version` 110000） |
| PyTorch | `2.13.0+rocm7.2` |
| ROCm / RCCL | 7.2.0 / 2.27.7 |
| 链路 | GPU 各 Gen4 x16，上行交换 Gen3 x8 |

---

## 2. 三个判据，先钉死再读数

| 判据 | 门限 | 本次结果 | 结论 |
|---|---|---|---|
| P2P 是否真的开了 | `canAccessPeer` 双向为真 + `isAllDirectP2p 1` + `via P2P/IPC` | 全部满足 | 通过 |
| 链路层收益 | RCCL 16 MB allreduce busbw 相对 SHM 提升 ≥20% | 3.96–4.14 → 5.03 GB/s | 通过 |
| 正确性 | 跨 rank latent 一致，且三轮 soak 全程 `max\|diff\| = 0.0` | 0.0 | 通过 |

---

## 3. RCCL 16 MB allreduce 微基准

同一条 `scripts/probe_allreduce.py`，只切换 `NCCL_TOPO_FILE`：

| 通道 | busbw | 相对 SHM |
|---|---|---|
| `via SHM/direct/direct` | 3.96–4.14 GB/s | 基线 |
| `via P2P/IPC` | **5.03 GB/s** | **+21% ~ +27%** |

判据修正的一条：**peer 直拷上限约 5.15 GB/s 不能和 collective 直接对比。** 5.15 GB/s 是单向 `copy`（一次搬运、一份 payload），collective 里每轮还要算上 reduce 与两次方向的收发；两者分母不同，把 5.15 当成 allreduce 的"应达值"会得出错误的"没跑满"结论。分开记：copy 上限 5.15 GB/s，collective 实测 5.03 GB/s。

---

## 4. 端到端（内部视频生成流水线，私有基准）

1920×1088 / 124 帧 / 4 步，同一份权重、同一组 prompt：

| 指标 | SHM | P2P | 变化 |
|---|---|---|---|
| 每步耗时 | 88.91 s | **85.00 s** | **−4.4%** |
| 每步 allreduce payload | 81.63 GB | 81.63 GB | 不变 |
| 每步通信耗时 | 19.7 s | **16.2 s** | −3.5 s |

链路带宽容量的提升能吃进来，但只吃进 4.4%：每步 81.63 GB 的 allreduce 摊在 85 s 里，通信仍不是主项。这解释了为什么纯 RCCL 微基准是 +21~27%，端到端却只有 −4.4%。

---

## 5. 稳定性 soak（加固版）

3 轮，每轮 1920×1088 / 124 帧 / 8 步：

| 轮次 | per_step | 端到端 |
|---|---|---|
| #1 | 85.88 s | 857.7 s |
| #2 | 85.99 s | 856.6 s |
| #3 | 85.97 s | 860.6 s |

| 观测项 | 结果 |
|---|---|
| 采样点 | 540 个（`scripts/p2p-watch.sh`，5 s 间隔） |
| 温度峰值 | 91.0 ℃（阈值 100 ℃） |
| 双卡功耗峰值 | 742 W |
| AER correctable 增量 | **0** |
| AER fatal | **0** |
| 内核异常事件（含 `kprobe missed` / GPU reset / ring timeout） | **0** |
| 跨 rank latent `max\|diff\|` | **0.0（三轮全部）** |

per_step 三轮离散度 0.11 s（85.88–85.99），端到端离散度 4.0 s（856.6–860.6），没有随轮次恶化的趋势。

---

## 6. 判据修正：md5 不能当正确性判据

| 比对方式 | 结果 | 能否作为判据 |
|---|---|---|
| 跨 rank latent `max\|diff\|`（同一轮、同一 prompt） | **0.0** | **能**，这是本次唯一采用的判据 |
| 跨轮输出 mp4 的 md5 | 不一致，latent `max\|diff\| = 4.116` | **不能** |

原因：流水线的采样与调度本身跨轮非确定性，同种子重跑也会得到不同的 latent。md5 相同只能说明"两次跑成了一模一样"，md5 不同完全不能说明"数据错了"。真正要验的是**同一轮里两个 rank 拿到的是不是同一份数**——所以判据写成跨 rank latent 一致，而不是输出文件 md5。

> 这一条同时修正了 v1 测试方案里「输出 md5 一致」的写法（见 [stability-testplan.md](stability-testplan.md) §8）。

---

## 7. 既有环境噪声（与本次改动无关）

`avcodec_send_frame() returned 22` 在历史日志里普遍存在，P2P 开启前就在打，本次三轮 soak 里也照旧出现，频次没有变化。它属于编码器封装层的既有噪声，不计入内核异常事件，也不进判据。

---

## 8. 覆盖度：测了什么，没测什么

| 项 | 状态 | 说明 |
|---|---|---|
| 冷启动一致性 | 通过 | 重启后 `canAccessPeer` 双向为真、`via P2P/IPC` |
| 拓扑缺失拦截 | 通过 | 删掉 / 写错 `NCCL_TOPO_FILE` 时 preflight 非 0 退出，不静默回 SHM |
| 4 h 长稳 | **未完成** | 实际只跑了 43 min（3 轮），约为计划的 1/5.6；4 h 门槛仍未验 |
| 内核升级（S2） | 未测 | 无备用内核，DKMS 路径未做端到端验证 |
| GPU reset / suspend-resume（S4） | 未测 | 破坏性工况，未进确认门 |
| IOMMU off / ACS 开（S6） | 未测 | 需 BIOS 改动与显示器在场 |
| 三卡 / 掉卡 / 换插槽（S12） | 未测 | 硬件变体未覆盖 |
| 山寨 X99 板（VT-d/ReBAR/ACS 不可控） | 不适用 | 本方案只针对原生 X99/C610；固件缺项时拒绝安装，理由见 README「Genuine X99 / C610 only」 |
| 4 进程双任务并发（S8） | 未测 | — |

结论按"已测项通过、未测项标明"给，不把 43 min 的结果写成 4 h 的结论。
