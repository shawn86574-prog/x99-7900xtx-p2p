#!/usr/bin/env bash
# 启动前自检：内核 P2P + RCCL 实际通道。不是 P2P/IPC 就退出，避免长任务跑在 SHM 上。
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/p2p-env.sh"

fail() { echo "[FAIL] $*" >&2; exit 1; }

[[ -d /sys/module/p2p_force ]] || fail "p2p_force 未加载；先运行 sudo bash ${DIR}/../kernel/install-p2p-kernel.sh，再重启"
grep -qw pci_p2pdma_distance_many /proc/kallsyms || fail "内核符号 pci_p2pdma_distance_many 不存在"
[[ -f "${NCCL_TOPO_FILE}" ]] || fail "拓扑文件不存在：${NCCL_TOPO_FILE}"

TORCHRUN="${TORCHRUN:-$(command -v torchrun || true)}"
[[ -n "${TORCHRUN}" && -x "${TORCHRUN}" ]] || fail "找不到 torchrun；请先把 torchrun 放进 PATH，或设置 TORCHRUN=/path/to/torchrun"

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

echo "[OK] RCCL 已走 P2P/IPC"
grep -E 'canAccessPeer|isAllDirectP2p|via P2P/IPC|allreduce 16MB' "${LOG}" | tail -8
