#!/usr/bin/env bash
# install-rccl-conf.sh —— 把伪造 PXB 拓扑写进 RCCL 的配置文件，使其不依赖环境变量继承。
#
# 为什么需要它：vLLM 的 EngineCore/Worker 进程 env 里没有 NCCL_*（实测 17/19 个变量、0 个 NCCL），
# 只靠 source p2p-env.sh 无法覆盖这些进程。RCCL 会先读 /etc/rccl.conf 再读环境变量，
# 环境变量优先，所以配置文件能在"环境被裁剪"的进程里兜底，且不妨碍各引擎用自己的拓扑。
#
# 用法：
#   sudo bash scripts/install-rccl-conf.sh              # 双卡可见版（vLLM / SGLang）
#   sudo bash scripts/install-rccl-conf.sh --single     # 单卡可见版（每进程只暴露一张卡）
#   sudo bash scripts/install-rccl-conf.sh --rollback   # 还原
#   sudo bash scripts/install-rccl-conf.sh --dry-run    # 只打印将写入的内容
set -euo pipefail

CONF=/etc/rccl.conf
BAK=/etc/rccl.conf.bak
P2P_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MODE=dual
ACTION=install
for a in "$@"; do
  case "$a" in
    --single)   MODE=single ;;
    --rollback) ACTION=rollback ;;
    --dry-run)  ACTION=dryrun ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数：$a" >&2; exit 2 ;;
  esac
done

if [[ "$MODE" == single ]]; then
  TOPO=/etc/p2p/topo-pxb-single.xml
  FALLBACK="$P2P_DIR/topo/fake_topo_single.xml"
else
  TOPO=/etc/p2p/topo-pxb.xml
  FALLBACK="$P2P_DIR/topo/fake_topo_p2p.xml"
fi

if [[ "$ACTION" == rollback ]]; then
  [[ $EUID -eq 0 ]] || { echo "[FAIL] 需要 root" >&2; exit 1; }
  if [[ -f "$BAK" ]]; then
    mv -f "$BAK" "$CONF"; echo "[OK] 已还原 $CONF"
  else
    rm -f "$CONF"; echo "[OK] 已删除 $CONF（原本不存在）"
  fi
  echo "[提示] 重启各引擎后生效"
  exit 0
fi

# 拓扑文件就位检查
[[ -f "$TOPO" ]] || {
  if [[ -f "$FALLBACK" ]]; then
    echo "[WARN] $TOPO 不存在，使用仓库内 $FALLBACK" >&2
    TOPO="$FALLBACK"
  else
    echo "[FAIL] 找不到拓扑文件：$TOPO / $FALLBACK" >&2
    echo "       先跑 bash scripts/gen-topo.sh$([[ $MODE == single ]] && echo ' --single-visible')" >&2
    exit 1
  fi
}

CONTENT="# /etc/rccl.conf —— 由 x99-7900xtx-p2p/scripts/install-rccl-conf.sh 生成
# RCCL 读取顺序：本文件 → 环境变量；环境变量优先。
# 拓扑形状：$([[ $MODE == single ]] && echo '单卡可见（每进程一张卡）' || echo '双卡可见（单进程两张卡）')
NCCL_TOPO_FILE=$TOPO
NCCL_P2P_DISABLE=0
NCCL_P2P_LEVEL=PXB"

if [[ "$ACTION" == dryrun ]]; then
  echo "--- 将写入 $CONF ---"; echo "$CONTENT"; exit 0
fi

[[ $EUID -eq 0 ]] || { echo "[FAIL] 需要 root（sudo bash $0）" >&2; exit 1; }

if [[ -f "$CONF" ]] && ! cmp -s <(printf '%s\n' "$CONTENT") "$CONF"; then
  cp -a "$CONF" "$BAK"
  echo "[OK] 已备份原配置到 $BAK"
fi

printf '%s\n' "$CONTENT" > "$CONF"
chmod 644 "$CONF"
echo "[OK] 已写入 $CONF"
echo "     拓扑：$TOPO"

# 冲突提醒：当前若存在单卡可见的启动器，它应通过环境变量覆盖
if [[ "$MODE" == dual && -f /etc/p2p/topo-pxb-single.xml ]]; then
  echo "[注意] 检测到 /etc/p2p/topo-pxb-single.xml："
  echo "       每进程只可见一张卡的启动器（如 ComfyUI TP2 双实例）必须在自己的 env 里"
  echo "       设置 NCCL_TOPO_FILE=/etc/p2p/topo-pxb-single.xml，否则会报 Ring 0: Asymmetric link!"
fi

echo "[提示] 重启各引擎后生效（RCCL 在进程内缓存参数）"
echo "[验证] bash scripts/p2p-verify-engines.sh"
