#!/usr/bin/env bash
# 在启动任何 RCCL 进程前 source 本文件：
#   source ~/x99-7900xtx-p2p/scripts/p2p-env.sh
# 作用：强制 RCCL 读取伪造 PXB 拓扑，并确保 P2P 不被环境变量关掉。
P2P_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export NCCL_TOPO_FILE="${NCCL_TOPO_FILE:-${P2P_DIR}/../topo/fake_topo_p2p.xml}"
if [[ ! -f "${NCCL_TOPO_FILE}" ]]; then
  echo "[FAIL] 拓扑文件不存在：${NCCL_TOPO_FILE}" >&2
  return 1 2>/dev/null || exit 1
fi

# 强制打开 P2P；PXB 是 RCCL 对同 switch 路径的等级。
export NCCL_P2P_DISABLE=0
export NCCL_P2P_LEVEL=PXB

# 只打开初始化日志，便于确认 isAllDirectP2p 和实际通道，不刷屏。
export NCCL_DEBUG="${NCCL_DEBUG:-INFO}"
export NCCL_DEBUG_SUBSYS="${NCCL_DEBUG_SUBSYS:-INIT}"
