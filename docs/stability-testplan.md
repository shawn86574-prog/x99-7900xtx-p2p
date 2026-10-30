# X99 双 7900 XTX · P2P 改动稳定性测试方案（优先级 P3）

> 版本 v1.1，2026-10-30（已按加固落地后的实际状态校正；原 v1 为 2026-10-29）。被测对象：`~/x99-7900xtx-p2p/` 这套 P2P 强制方案。
> 目的：回答三个问题——(1) 这些改动会不会影响系统稳定性；(2) 哪些极端工况下会失效；(3) 失效后怎么救、平时怎么监。

---

## 0. 任务卡

```
任务：验证 p2p_force + 伪造拓扑这套改动对系统稳定性的影响，并给出失效边界与补救路径
边界：只测 P2P 相关改动，不评估模型生成质量、不评估 PCIe 4.0 平台、不改 BIOS/插槽
      下游消费方是"日常跑视频生成任务的这台机器"，输出必须可被直接执行
红线：1) 任何工况下不允许"静默数据错"——错必须能被检出
      2) 任何工况下失效必须可退化（退回 SHM 仍能跑完），不允许 hang/panic 当默认结局
      3) 破坏性工况（内核升级、IOMMU、GPU reset）必须先进确认门，且回滚命令在手
验收：见 §4 每行判据 + §8 汇总门槛（用数字钉死，不靠感觉）
交付：本方案 + `scripts/p2p-watch.sh` 观测口；每轮实验按"数量+关键摘要+状态"汇报
反馈：失败按"失效模式类别"归档，写入教训库，下次同类工况先查
```

---

## 1. 被测改动面

| # | 改动 | 落地位置 | 生效方式 | 回滚动作 | 风险级 |
|---|---|---|---|---|---|
| C1 | `p2p_force.ko`：kretprobe 劫持 `pci_p2pdma_distance_many`，**仅当 `provider->vendor == 0x1002` 时**返回 1，其余放行真实值，`maxactive=32` | `/lib/modules/7.0.0-38-generic/updates/dkms/p2p_force.ko.zst` | 加载即生效，全局 | `dkms remove p2p-force/1.0 --all` + `depmod` + 重启 | 高 |
| C2 | `softdep amdgpu pre: p2p_force` | `/etc/modprobe.d/99-p2p-force.conf` | 开机模块加载顺序 | 删该文件 + 重启 | 中 |
| C3 | 伪造 PXB 拓扑（虚拟桥 `04:00.0` 下挂 `05:00.0` / `08:00.0`） | `~/x99-7900xtx-p2p/topo/fake_topo_p2p.xml` | 进程级，靠 `NCCL_TOPO_FILE` | 不设该变量即退回 SHM | 中（数据正确性） |
| C4 | 运行期环境 `NCCL_TOPO_FILE` / `NCCL_P2P_LEVEL=PXB` / `NCCL_P2P_DISABLE=0` | 启动 shell 或 `scripts/p2p-env.sh` | 进程级 | 取消变量 | 低 |
| C5 | 固化：DKMS（`p2p-force/1.0`）、`update-initramfs`、`/etc/p2p/topo-pxb.xml`、`/etc/profile.d/p2p-rccl.sh`、开机自检 `p2p-bootcheck.service` | `kernel/install-p2p-kernel.sh --dkms` | 开机自动 | 按 §5.1 L2 逐项删除 | 中 |

关键性质：C1 改的是**全局内核符号**，影响面取决于谁调用它；C3 只改**单个进程看到的拓扑**。

---

## 2. 已核实基线（这些不必重复测）

| 事实 | 值 | 对测试的意义 |
|---|---|---|
| 内核污染 `tainted` | 12289 = 0x3001（bit0 专有 nvidia + bit12 树外 + bit13 未签名） | 崩溃后上游不会受理；取证要自己留 |
| Secure Boot | disabled，Platform 在 Setup Mode | 未签名模块能加载；若日后开启需先签 |
| `pci_p2pdma_distance_many` 导入者 | `amdgpu`、`xe`、`habanalabs`、`nvmet` | **本机只加载了 amdgpu**，劫持实际只作用于它；启用 nvmet/xe 即扩大风险面 |
| amdgpu 是否在 initramfs | 否（`lsinitramfs` 匹配 0 个） | `softdep` 开机顺序可控，C2 有效 |
| 现有固化程度 | DKMS 模块 + `99-p2p-force.conf` + `/etc/p2p/topo-pxb.xml` + `profile.d/p2p-rccl.sh` + `p2p-bootcheck.service`，已 `update-initramfs` | 内核升级由 DKMS 自动重编，但未做端到端验证（S2） |
| 观测接口 | 3 路温度、`power1_average`、`aer_dev_correctable/fatal`、`current_link_speed/width` 均可读 | 采样器不需要 root |
| 内核日志 | `dmesg_restrict=1`，`journalctl -k` 对当前用户可读 | 观测口用 journalctl |
| 可用内核 | 只有 `7.0.0-38-generic` 一个 | **S2 之前必须先装一个备用内核**，否则测完无法回退 |
| 崩溃取证 | `crashkernel` 未设、pstore 空 | 硬崩只有 journal 前一条，无 vmcore |

---

## 3. 风险登记表（每条都要能落到一个判据）

| ID | 失效模式 | 触发条件 | 预期后果 | 判据（通过 = 不算失效） |
|---|---|---|---|---|
| R1 | 符号劫持越界：非 amdgpu 驱动拿到假距离 | 加载 `nvmet`/`xe`/`habanalabs`，或未来换平台 | 非 P2P 设备被当 peer，DMA 到非法 BAR → 数据错或 AER 风暴 | 已按 provider 厂商过滤（仅 `0x1002`）；S11 复核调用者仍只有 amdgpu |
| R2 | 假距离套用到不支持 peer 的设备 | 插第三张卡、换插槽、GPU 掉卡后重扫 | amdgpu 对不可达对端开 peer，GPU hang/reset | 三卡/掉卡工况下仍能启动、能跑 SHM |
| R3 | `maxactive=32` 溢出 | 并发 probe 突增（unbind/rebind 风暴） | kretprobe miss → 本次退回真实值 → 退化 SHM（功能丢失，不崩） | journal 无大量 `kprobe missed`；功能可恢复 |
| R4 | 内核升级后模块失配 | `apt install linux-image-*` 后重启 | `p2p_force` 加载失败，P2P 静默消失；极端情况 amdgpu 加载报错 | 升级后要么 P2P 正常，要么明确退化 SHM 且任务能跑 |
| R5 | 加载顺序失效 | 改 initramfs 内容、amdgpu 被提前加载 | 与 R4 同：退化 SHM | 冷启动 3/3 双向 peer True |
| R6 | 卸载/重载竞态 | `rmmod p2p_force` 与 amdgpu probe / GPU reset 并发 | 已在跑的 hook 被摘，崩溃风险 | 10 次并发卸载无 oops |
| R7 | GPU reset / 挂起恢复后 peer 映射未重建 | `amdgpu_gpu_recover`、suspend/resume、AER 后重置 | P2P 访问读回脏数据或触发二次错误 | reset 后 allreduce golden 校验仍 0 错 |
| R8 | 链路降速/掉宽 | 高温、插槽接触、`setpci` 限速到 Gen1 | 带宽掉到 1 GB/s 级，P2P 名义在但不划算 | 带宽下降要有告警；不得数据错 |
| R9 | 静默数据错（最危险） | peer BAR 映射不可靠、ACS 打开、IOMMU 配置异常 | allreduce 结果错但无报错 | 10⁶ 元素随机 ×200 轮 bad=0；跨 rank latent 一致 |
| R10 | 资源冲突 | 一个常驻显存的服务（下称 background-service）占 47 GB `/dev/shm`、双任务并发 4 进程 | OOM kill、超时、显存溢出 | 并发工况下任务完成且不 OOM |

---

## 4. 极端工况矩阵

> P 列 = 执行批次（P3-1 低成本随时做 / P3-2 需双卡空闲 / P3-3 需停机窗口）。
> 资源门：background-service 必须 inactive，两个推理实例必须退出，`rocm-smi` 或 sysfs 显示功耗 <40 W。

### P3-1 随时可做（不占双卡，单进程即可）

| ID | 工况 | 命令要点 | 判据 |
|---|---|---|---|
| S11 | 调用者审计 | `sudo bpftrace -e 'kprobe:pci_p2pdma_distance_many { @[kstack(1)] = count(); }'` 跑 5 min | 调用栈只出现 amdgpu；出现 nvmet/xe 立即停用 C1 |
| S13 | 拓扑缺失/写错 | 删除 XML、把 `dev="1"` 改成 `dev="3"`，跑 preflight | preflight 必须拦截退出（非 0），不许静默跑 SHM |
| S3 | 模块卸载/重载并发 | 10 次 `rmmod`/`modprobe` 循环，中间穿插 `preflight` | 无 oops；结束后再 preflight 仍 `isAllDirectP2p 1` |
| S14 | lockdown / kptr 限制 | 读 `kptr_restrict`，模拟 `lockdown=confidentiality`（仅评估，不重启） | 注册失败要能明确报错，amdgpu 仍可用 |

### P3-2 需双卡空闲

| ID | 工况 | 命令要点 | 判据 |
|---|---|---|---|
| S1 | 冷启动 ×3 | 重启后立刻 `p2p-preflight.sh`，记录 BDF | 3/3 `canAccessPeer` 双向 True、`via P2P/IPC` |
| S5 | 链路降速 | `setpci -s 04:00.0 CAP_EXP+0x30.w=...` 限到 Gen2（可回滚） | 带宽按比例下降且无 AER；恢复后回到 ≥4.5 GB/s |
| S7 | 内存压力 | 启动 background-service 后再跑 P2P 微基准与 1920 小步数 | 不 OOM；若 OOM 记录峰值并给出共存策略 |
| S8 | 双任务并发 | 两套 TP2 共 4 进程同时 init + 各跑 1 步 | 全部成功；无超时；带宽记录（预期跌破 3 GB/s） |
| S12 | 硬件变体 | 只插一张卡 / 换插槽 / 插三张卡 | 要么正常，要么 preflight 拒绝并给明确原因 |
| S9 | 4 h soak | `p2p-watch.sh -i 5 -d 14400` + 循环 1920/124f/8 步 | 温度 ≤100 ℃、AER fatal=0、correctable 增量 ≤100、无 GPU reset、带宽漂移 <10% |

### P3-3 需停机窗口 + 回滚包（最高风险）

| ID | 工况 | 前置 | 判据 |
|---|---|---|---|
| S2 | 内核升级 | **先装一个备用内核并确认能启动**；记录当前 grub 项 | 升级后：DKMS 重编则 P2P 恢复；未重编则明确退化 SHM 且能跑完任务 |
| S4 | GPU reset / suspend-resume | 备份当前 `canAccessPeer`、golden 基线 | reset 后 allreduce golden 0 错；失败则记录并禁 P2P |
| S6 | IOMMU off / ACS 开 | BIOS 或 cmdline 改动，需串口/显示器在场 | 必须拒绝而非数据错；出现数据错即判定方案不安全 |
| S10 | kretprobe 压测 | 并发 unbind/rebind 制造高频调用 | 统计 `kprobe missed`，确认退化路径 |

---

## 5. 补救措施

### 5.1 分级回滚

| 级别 | 动作 | 生效时间 | 彻底程度 |
|---|---|---|---|
| L0 单任务 | 不设 `NCCL_TOPO_FILE`（或 `scripts/p2p-env.sh` 不 source） | 立即，下一进程 | 只影响该任务，退回 SHM |
| L1 停用内核劫持 | `rmmod p2p_force` | 立即 | **不彻底**：已 probe 完的 amdgpu 仍认为 peer 可达，直到 amdgpu 重新 probe 或重启 |
| L2 移除固化 | `dkms remove p2p-force/1.0 --all` → 删 `/etc/modprobe.d/99-p2p-force.conf`、`/etc/profile.d/p2p-rccl.sh`、`/etc/p2p/topo-pxb.xml` → `depmod -a` | 下次重启 | 彻底 |
| L3 整机 | grub 选备用内核 / Live USB | 5 min 内 | 彻底，且保留原系统 |

> 红线：先 L0 再 L1，任何"数据错"症状一律先退 SHM 再查原因，不要边猜边跑长任务。

### 5.2 加固项（可选实现，需重编 + 重启）

- **H1 收窄劫持范围**：只在调用者属于 amdgpu 时篡改返回值，其余放行。避免 R1/R2 扩大到别的驱动。（仓库内的 [`../kernel/p2p_force.c`](../kernel/p2p_force.c) 已按此实现，判据是 `provider->vendor == PCI_VENDOR_ID_ATI`。）

```c
static int entry_handler(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	struct pci_dev *provider = (struct pci_dev *)regs_get_kernel_argument(regs, 0);
	int *flag = (int *)ri->data;

	/* provider 是本次查询的对端设备；只有 AMD 显卡才值得伪造可达性 */
	*flag = (provider && provider->vendor == PCI_VENDOR_ID_ATI) ? 1 : 0;
	return 0;
}

static int ret_handler(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	if (*(int *)ri->data)
		regs_set_return_value(regs, 1);
	return 0;
}
```

> 注：初版曾用 `__module_text_address(instruction_pointer(regs))` 判调用者，但 `7.0.0-38-generic` 未导出该符号（`modpost: "__module_text_address" undefined!`），无法链接；改为在 entry handler 读 `provider->vendor`，效果等价且只依赖已导出的 API。

- **H2 白名单化对端**：只对 `1002:744c` 返回 1，其余保持真实值，防第三张卡/掉卡场景。
- **H3 双通道自愈**：preflight 失败时自动回退到 SHM 并继续任务（而不是直接退出），把"失败"从停机变成降速。

### 5.3 失效后的处置顺序

1. 判类别：崩溃/挂起 → 看 journal 最后 200 行 + `tainted`；数据错 → 比对 golden；带宽塌陷 → 看链路与温度。
2. 执行 L0 退回 SHM，确认任务能跑。
3. 复现最小用例（微基准或 preflight），定位是 C1、C3 还是硬件。
4. 归档到教训库：工况 → 失效模式 → 判据 → 处置。

---

## 6. 监测口

| ID | 观测口 | 状态 | 说明 |
|---|---|---|---|
| M1 | `scripts/p2p-watch.sh` | **已实现，已冒烟** | 5 s 采样：`tainted`、模块在位、KFD p2p 链路数、温度峰值、功耗、AER correctable/fatal、链路速率/宽度、内核异常事件计数；越界打 `[ALERT]`，CSV 落盘 |
| M2 | `scripts/p2p-preflight.sh` | 已有 | 每次跑任务前判 `isAllDirectP2p 1` + `via P2P/IPC` |
| M3 | golden 校验 | 待实现（P3-2） | 10⁶ float32 随机 ×200 轮 allreduce 与 CPU 参考比对；跨 rank latent 对照，不用输出 md5 |
| M4 | 调用者审计 | 待执行（S11） | bpftrace 打印调用栈，一次性确认 R1 |
| M5 | 崩溃取证 | 缺口 | 现无 `crashkernel`、pstore 空；建议加 `crashkernel=256M` + `efi_pstore`，并把 `tainted` 快照写进实验记录 |

采样命令：

```bash
bash ~/x99-7900xtx-p2p/scripts/p2p-watch.sh -i 5 -d 14400 -o ~/p2p-logs/soak.csv
```

当前基线（22:24 冒烟）：`tainted=12289`、模块在位、KFD 链路 2 条、温度 44 ℃、功耗 25 W、AER 全 0、链路 `16.0GT/s x16`。

---

## 7. 排期与资源门（P3）

| 批次 | 内容 | 资源条件 | 预计占用 |
|---|---|---|---|
| P3-1 | S11 S13 S3 S14 | 任意空闲时段，单卡 | 分散进行，不占双卡 |
| P3-2 | S1 S5 S7 S8 S12 S9 | 双卡全空、background-service 停、无推理实例 | 4 h soak 是主体 |
| P3-3 | S2 S4 S6 S10 | 停机窗口 + 备用内核 + 显示器/串口 | 一次 30–60 min 窗口 |

前置动作（做 P3 之前必须先补）：

1. 装一个备用内核并验证能启动（否则 S2/S4/S6 无退路）。
2. ~~把 P2P 固化做完整~~（已完成：DKMS + initramfs + 开机自检 service 均已落地并冷启动验证）。
3. ~~决定是否实现 H1 加固~~（已完成：`kernel/p2p_force.c` 已按 provider 厂商过滤，冷启动 dmesg 已确认）。

---

## 8. 验收与汇报格式

汇总门槛（全部满足才算"改动不伤稳定性"）：

| 项 | 门槛 |
|---|---|
| 冷启动一致性 | 3/3 次双向 peer True + `via P2P/IPC` |
| 数据正确性 | golden 200 轮 bad=0；跨 rank latent 一致（同种子的输出 md5 **不可**作为判据，见 [test-results.md](test-results.md)） |
| 长稳 | 4 h 无 oops/panic/GPU reset；温度 ≤100 ℃；AER fatal=0，correctable 增量 ≤100 |
| 退化能力 | 每类失效场景都能退回 SHM 并跑完，无需重装系统 |
| 性能不倒退 | P2P 通道 ≥4.5 GB/s；1920 档 step ≤90 s |
| 回滚 | L0 ≤30 s，L2 一次重启内完成 |

汇报格式（每批结束后）：

```
批次：P3-x
执行：S… 共 n 项，通过 m 项，失败 k 项
关键摘要：<失效工况 → 失效模式 → 是否可退化 → 处置>
状态：<是否继续下一批 / 是否需要加固 / 是否建议停用>
CSV：<路径>
```

---

## 9. 待你定的三个点

1. **加固是否做**：H1（限定 amdgpu 调用者）改动小，能直接消掉 R1 的大半风险；H2 更严但要维护设备白名单。
2. **固化到什么程度**：只留在项目目录（现状，换 shell 就退化），还是进 `/etc` + systemd 自检（稳定但增加系统面）。
3. **备用内核**：现在就装一个，还是把 S2 整条从测试里剔除。
