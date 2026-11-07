#!/usr/bin/env bash
# tp2-guard.sh —— 「默认 TP=2 双实例 + P2P」策略闸（source 使用，不是独立进程）
#
# 用法（在启动器脚本里接线，放在所有环境变量导出之后、最终 exec 之前）：
#   GUARD=/home/jay/work/x99-7900xtx-p2p/scripts/tp2-guard.sh
#   [ -f "$GUARD" ] || { echo "[tp2-guard] 守卫缺失：$GUARD（策略闸不可绕过，请恢复）" >&2; exit 1; }
#   source "$GUARD"
#   tp2_guard_upgrade "$SCRIPT_DIR/ComfyUI" "$PY_EXE" || exit 1
#   exec ...   # 仅在放行单卡时才会走到这里
#
# 语义（策略见 docs/tp2-default-policy.md）：
#   - 默认：单卡形态入口 → 弹提示框，然后**静默改道**启动 TP=2 双实例 + P2P（exec 到 run_tp.sh 2）
#   - TP_ALLOW_SINGLE=1：用户本人显式指定单卡 → 提示一行并放行，调用方继续原单卡路径
#
# 为什么必须「改道」而不是「设 COMFY_TP_WORLD=2」：环境变量造不出第二个进程，
# 单进程拿 world=2 会在 rendezvous 处等永远不来的 rank1，挂死 NCCL 30 分钟。

TP2_LAUNCHER=${TP2_LAUNCHER:-/home/jay/tp2/run_tp.sh}
TP2_BASE_PORT=${TP2_BASE_PORT:-8191}
TP2_TAG=${TP2_TAG:-autoguard}

# 提示框：有图形环境且装了 zenity 就弹 6 秒自动关的框（不阻塞），否则终端画框
_tp2_notice() {
  local msg="$1"
  echo "[tp2-guard] $msg" >&2
  if [ -n "${DISPLAY:-}" ] && command -v zenity >/dev/null 2>&1; then
    zenity --info --title="默认策略 · TP=2 + P2P" --width=420 \
           --timeout=6 --text="$msg" >/dev/null 2>&1 &
  else
    echo "+----------------------------------------------------------+" >&2
    echo "| $msg" | fmt -w 60 >&2
    echo "+----------------------------------------------------------+" >&2
  fi
}

# 入口：单卡入口检测 → 提示 + 静默改道；显式单卡则放行（return 0）
# 参数1：ComfyUI 目录  参数2：Python 解释器
tp2_guard_upgrade() {
  local comfy="${1:-}" py="${2:-}"
  if [ "${TP_ALLOW_SINGLE:-0}" = "1" ]; then
    echo "[tp2-guard] TP_ALLOW_SINGLE=1：按用户显式指定，以单卡模式启动。" >&2
    return 0
  fi
  [ -f "$TP2_LAUNCHER" ] || { echo "[tp2-guard] 找不到 TP 启动器：$TP2_LAUNCHER（策略闸不可绕过，请恢复）" >&2; return 1; }
  _tp2_notice "检测到单卡启动入口。按默认策略，正在静默启动 TP=2 双实例 + P2P（端口 ${TP2_BASE_PORT}/$((TP2_BASE_PORT + 1))）。单卡定制请设 TP_ALLOW_SINGLE=1。"
  # 改道：继承调用方已导出的全部环境（HF_* 等），指向同一套 ComfyUI 安装
  [ -n "$comfy" ] && export COMFY="$comfy"
  [ -n "$py" ] && export PY="$py"
  export COMFY_TP_VAE_SPLIT=${COMFY_TP_VAE_SPLIT:-1}
  # 保留原入口的开浏览器行为
  EXTRA_ARGS="${EXTRA_ARGS---use-ck-attention --mmap-torch-files}"
  case " $EXTRA_ARGS " in *" --auto-launch "*) ;; *) EXTRA_ARGS="$EXTRA_ARGS --auto-launch";; esac
  export EXTRA_ARGS
  exec bash "$TP2_LAUNCHER" 2 "$TP2_BASE_PORT" "$TP2_TAG"
}

# 兼容旧名：曾经的硬失败实现，如今等同于改道（保留给已接线的调用方）
tp2_guard_or_fail() {
  tp2_guard_upgrade "${COMFY:-}" "${PY:-}" || exit 1
}
