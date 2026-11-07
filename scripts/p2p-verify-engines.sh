#!/usr/bin/env bash
# p2p-verify-engines.sh —— 逐个检查在跑的引擎进程能否读到 P2P 所需的环境/配置。
#
# 判据：真正调用 RCCL 的进程里，NCCL_TOPO_FILE 必须可见（env 或 /etc/rccl.conf 兜底）。
# 用法：bash scripts/p2p-verify-engines.sh
set -uo pipefail

CONF=/etc/rccl.conf
DUAL=/etc/p2p/topo-pxb.xml
SINGLE=/etc/p2p/topo-pxb-single.xml

echo "=== 配置文件"
if [[ -f "$CONF" ]]; then
  echo "[OK]   $CONF 存在"
  grep -E '^NCCL_' "$CONF" | sed 's/^/       /'
  TOPO_CONF=$(grep -E '^NCCL_TOPO_FILE=' "$CONF" | cut -d= -f2-)
  [[ -f "$TOPO_CONF" ]] && echo "[OK]   配置指向的拓扑存在：$TOPO_CONF" \
                        || echo "[FAIL] 配置指向的拓扑不存在：$TOPO_CONF"
else
  echo "[WARN] $CONF 不存在 —— 目前只依赖环境变量，遇到会重建 env 的框架（如 vLLM worker）就会失效"
  echo "       修复：sudo bash scripts/install-rccl-conf.sh"
fi

echo
echo "=== 拓扑文件"
for f in "$DUAL" "$SINGLE"; do
  [[ -f "$f" ]] && echo "[OK]   $f ($(stat -c%s "$f") B)" || echo "[--]   $f 不存在"
done

echo
echo "=== 引擎进程（env 里的 NCCL_* 计数）"
found=0
for p in /proc/[0-9]*; do
  pid=${p#/proc/}
  cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null || true)
  case "$cmd" in
    *"vllm"*|*"VLLM::"*|*"sglang"*|*"ComfyUI"*|*"main.py"*)
      found=1
      n=$(tr '\0' '\n' < "$p/environ" 2>/dev/null | grep -c '^NCCL_' || true)
      topo=$(tr '\0' '\n' < "$p/environ" 2>/dev/null | grep '^NCCL_TOPO_FILE=' | cut -d= -f2- || true)
      vis=$(tr '\0' '\n' < "$p/environ" 2>/dev/null | grep -E '^(CUDA|HIP)_VISIBLE_DEVICES=' | cut -d= -f2- | tr '\n' ',' || true)
      shape="双卡可见"
      [[ "$vis" == *,* ]] || { [[ -n "$vis" ]] && shape="单卡可见"; }
      if [[ -n "$topo" ]]; then
        echo "[OK]   pid=$pid NCCL_=$n 拓扑=$topo ($shape)"
      elif [[ -n "$n" && "$n" -gt 0 ]]; then
        echo "[OK]   pid=$pid NCCL_=$n 拓扑未显式指定 → 走 $CONF ($shape)"
      else
        echo "[FAIL] pid=$pid NCCL_=0 无拓扑；$( [[ -f "$CONF" ]] && echo '应由 /etc/rccl.conf 兜底' || echo '且无 /etc/rccl.conf → 必然走 SHM' )"
      fi
      echo "       ${cmd:0:100}"
      ;;
  esac
done
[[ "$found" = 1 ]] || echo "[--]   当前没有相关引擎进程在跑"

echo
echo "=== 运行期铁证（需引擎侧开启 NCCL_DEBUG=INFO NCCL_DEBUG_SUBSYS=INIT）"
echo "    期望：NCCL_TOPO_FILE set by environment to ... / isAllDirectP2p 1 / via P2P/IPC"
echo "    失败：via SHM/direct/direct"
