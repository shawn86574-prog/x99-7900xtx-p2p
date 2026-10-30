#!/usr/bin/env bash
# 启动前自检：先验环境前提，再验 RCCL 实际通道。
# 任一前提不满足即退出，避免“以为走 P2P、实际走 SHM”或长任务跑在错误配置上。
#   bash scripts/p2p-preflight.sh
#   bash scripts/p2p-preflight.sh --env-only   # 只做环境检查，不跑探针
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/p2p-env.sh"

ENV_ONLY=0
[[ "${1:-}" == "--env-only" ]] && ENV_ONLY=1

fail() { echo "[FAIL] $*" >&2; exit 1; }
warn() { echo "[WARN] $*" >&2; }
ok()   { echo "[OK]   $*"; }

KFD=/sys/class/kfd/kfd/topology/nodes
gpu_rows() {
  # 输出：BDF device_id gfx_target_version，每个物理 GPU 一行
  for d in "${KFD}"/*; do
    simd=$(awk '/^simd_count/{print $2}' "$d/properties" 2>/dev/null || true)
    [[ "${simd:-0}" -gt 0 ]] || continue
    loc=$(awk '/^location_id/{print $2}' "$d/properties")
    did=$(awk '/^device_id/{print $2}' "$d/properties")
    gfxv=$(awk '/^gfx_target_version/{print $2}' "$d/properties")
    bus=$(( (loc >> 8) & 0xff ))
    devn=$(( (loc & 0xff) >> 3 ))
    fn=$(( loc & 7 ))
    printf '0000:%02x:%02x.%d %s %s\n' "${bus}" "${devn}" "${fn}" "${did}" "${gfxv}"
  done
}

# ---------- 环境前提 ----------
[[ -d "${KFD}" ]] || fail "KFD 不可用：amdgpu 未加载或 /dev/kfd 缺失"

amod=$(modinfo -n amdgpu 2>/dev/null || true)
case "${amod}" in
  "") fail "modinfo 查不到 amdgpu" ;;
  *"(builtin)"*) fail "amdgpu 被编译进内核。钩子只能在模块加载时挂上，built-in 时 amdgpu 已先 probe，必须换成模块化内核" ;;
esac
ok "amdgpu 是模块：${amod}"

cfg="/boot/config-$(uname -r)"
if [[ -r "${cfg}" ]]; then
  grep -q '^CONFIG_KRETPROBES=y' "${cfg}" || fail "内核缺少 CONFIG_KRETPROBES"
  grep -q '^CONFIG_PCI_P2PDMA=y' "${cfg}" || fail "内核缺少 CONFIG_PCI_P2PDMA"
  ok "内核开启 KRETPROBES / PCI_P2PDMA"
else
  grep -qw register_kretprobe /proc/kallsyms || fail "内核没有 register_kretprobe，kretprobe 不可用"
  ok "内核kallsyms 含 register_kretprobe（无 ${cfg}，按符号判断）"
fi

if tr ' ' '\n' < /proc/cmdline | grep -qx 'iommu=off'; then
  fail "cmdline 带 iommu=off：VRAM BAR 在 44-bit DMA mask 之上，P2P 需要 IOMMU 翻译"
fi
if tr ' ' '\n' < /proc/cmdline | grep -qx 'iommu=pt'; then
  warn "cmdline 带 iommu=pt（passthrough）；本机验证条件是 translated，若后续 P2P 失败先去掉该参数"
fi

rows=$(gpu_rows)
[[ -n "${rows}" ]] || fail "KFD 里没有 GPU 节点"

gpu_count=$(printf '%s\n' "${rows}" | grep -c . || true)
[[ "${gpu_count}" -ge 2 ]] || fail "只看到 ${gpu_count} 张 AMD GPU；本方案至少需要 2 张"

while read -r bdf _did _gfxv; do
  [[ -e "/sys/bus/pci/devices/${bdf}/iommu_group" ]] \
    || fail "${bdf} 没有 IOMMU group（IOMMU 关闭或设备未纳入）；P2P 需要 IOMMU 翻译模式"
done <<< "${rows}"
ok "两张 GPU 都在 IOMMU group 内（${gpu_count} 张可见）"

gfx_unique=$(printf '%s\n' "${rows}" | awk '{print $3}' | sort -u | wc -l)
[[ "${gfx_unique}" -eq 1 ]] || fail "可见 GPU 的 gfx 架构不一致：$(printf '%s\n' "${rows}" | awk '{print $3}' | sort -u | tr '\n' ' ')；跨架构不做 peer 访问"
gfxv=$(printf '%s\n' "${rows}" | awk 'NR==1{print $3}')
ok "GPU 架构一致：gfx$(( gfxv / 10000 ))$(( (gfxv / 100) % 100 ))$(( gfxv % 100 ))"

[[ -f "${NCCL_TOPO_FILE}" ]] || fail "拓扑文件不存在：${NCCL_TOPO_FILE}"
topo_bdfs=$(awk '/class="0x030000"/{ if (match($0,/busid="[^"]*"/)) print substr($0,RSTART+7,RLENGTH-8) }' "${NCCL_TOPO_FILE}" | sort)
real_bdfs=$(printf '%s\n' "${rows}" | awk '{print $1}' | sort)
if [[ "${topo_bdfs}" != "${real_bdfs}" ]]; then
  fail "拓扑文件里的 GPU 地址与实机不一致。\\n  实机：$(echo ${real_bdfs})\\n  拓扑：$(echo ${topo_bdfs})\\n  修复：bash scripts/gen-topo.sh 重新生成"
fi
ok "拓扑文件 GPU 地址与实机一致：$(echo ${real_bdfs})"

TORCHRUN="${TORCHRUN:-$(command -v torchrun || true)}"
[[ -n "${TORCHRUN}" && -x "${TORCHRUN}" ]] || fail "找不到 torchrun；请先把 torchrun 放进 PATH，或设置 TORCHRUN=/path/to/torchrun"

PYBIN="${TORCHRUN%/*}/python"
if [[ -x "${PYBIN}" ]]; then
  rccl=$(timeout 20 "${PYBIN}" - <<'PY' 2>/dev/null || true
import torch
print("%d.%d.%d" % torch.cuda.nccl.version())
PY
)
  case "${rccl}" in
    2.27.*) ok "RCCL ${rccl}" ;;
    "") warn "读不到 RCCL 版本（torch 可能未装 nccl 绑定）；跳过版本判定" ;;
    *) warn "RCCL ${rccl} 不是 2.27.x；本仓库的路径判定结论只在 2.27.7 上验证过，新版可能已修正 Intel x86 的 PATH_PXB 硬编码" ;;
  esac
fi

if [[ "${ENV_ONLY}" = "1" ]]; then
  echo "[OK] 环境前提全部满足（未跑探针）"
  exit 0
fi

# ---------- 通道验证 ----------
[[ -d /sys/module/p2p_force ]] || fail "p2p_force 未加载；先运行 sudo bash ${DIR}/../kernel/install-p2p-kernel.sh，再重启"
grep -qw pci_p2pdma_distance_many /proc/kallsyms || fail "内核符号 pci_p2pdma_distance_many 不存在"

LOG="$(mktemp -t p2p-preflight.XXXXXX.log)"
trap 'rm -f "${LOG}"' EXIT

if ! "${TORCHRUN}" --nproc_per_node=2 "${DIR}/probe_allreduce.py" >"${LOG}" 2>&1; then
  tail -80 "${LOG}"
  fail "探针运行失败"
fi

if ! grep -q 'isAllDirectP2p 1' "${LOG}"; then
  grep -E 'isAllDirectP2p|via ' "${LOG}" || true
  fail "RCCL 未判定 direct P2P；检查 NCCL_TOPO_FILE 是否为 PXB 拓扑"
fi

if ! grep -q 'via P2P/IPC' "${LOG}"; then
  grep -E 'isAllDirectP2p|via ' "${LOG}" || true
  fail "实际通道不是 P2P/IPC；拒绝回落到 SHM"
fi

ok "RCCL 已走 P2P/IPC"
grep -E 'canAccessPeer|isAllDirectP2p|via P2P/IPC|allreduce 16MB' "${LOG}" | tail -8
