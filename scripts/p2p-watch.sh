#!/usr/bin/env bash
# p2p_watch.sh — P2P 稳定性观测口
# 周期采样内核/PCIe/GPU 指标写 CSV，越界立即打印 [ALERT]。只读，不改任何系统状态。
# 用法: p2p_watch.sh [-i 5] [-d 14400] [-o logs/watch.csv]
set -u

INTERVAL=5
DURATION=0
OUT=""
while getopts "i:d:o:" opt; do
  case "$opt" in
    i) INTERVAL=$OPTARG ;;
    d) DURATION=$OPTARG ;;
    o) OUT=$OPTARG ;;
    *) echo "用法: $0 [-i 间隔秒] [-d 总时长秒] [-o csv]"; exit 2 ;;
  esac
done

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT=${OUT:-$DIR/logs/watch_$(date +%Y%m%d_%H%M%S).csv}
mkdir -p "$(dirname "$OUT")"

START_EPOCH=$(date +%s)
START_TS=$(date '+%Y-%m-%d %H:%M:%S')
TEMP_MAX_MC=100000   # 100 ℃，阈值 110 ℃ 会降频，留 10 ℃ 余量
AER_CORR_MAX=100     # 一次实验允许的可纠正错误增量上限

GPU_DIRS=$(for d in /sys/class/drm/card*/device; do
  [ "$(cat "$d/vendor" 2>/dev/null)" = "0x1002" ] && echo "$d"
done)

kfd_links() {
  local n=0 v
  for f in /sys/class/kfd/kfd/topology/nodes/*/properties; do
    v=$(awk '/^p2p_links_count/{print $2}' "$f" 2>/dev/null)
    n=$((n + ${v:-0}))
  done
  echo "$n"
}

gpu_max_temp() {
  local t=0 v
  for d in $GPU_DIRS; do
    for f in "$d"/hwmon/hwmon*/temp*_input; do
      [ -r "$f" ] || continue
      v=$(cat "$f" 2>/dev/null)
      [ -n "$v" ] && [ "$v" -gt "$t" ] && t=$v
    done
  done
  echo "$t"
}

gpu_power_w() {
  local s=0 v
  for d in $GPU_DIRS; do
    for f in "$d"/hwmon/hwmon*/power1_average; do
      [ -r "$f" ] || continue
      v=$(cat "$f" 2>/dev/null)
      [ -n "$v" ] && s=$((s + v / 1000000))
    done
  done
  echo "$s"
}

# $1 = aer_dev_correctable | aer_dev_fatal
aer_sum() {
  local s=0 v
  for f in /sys/bus/pci/devices/*/"$1"; do
    [ -r "$f" ] || continue
    v=$(awk '{s+=$2} END{printf "%d", s+0}' "$f" 2>/dev/null)
    s=$((s + ${v:-0}))
  done
  echo "$s"
}

link_state() {
  local out=""
  for d in $GPU_DIRS; do
    out="$out $(cat "$d/current_link_speed" 2>/dev/null | tr -d ' ')"x"$(cat "$d/current_link_width" 2>/dev/null)"
  done
  echo "${out# }"
}

# 统计自本脚本启动以来的内核异常事件（NVRM/Xid 属亮机卡噪声，剔除）
kernel_events() {
  journalctl -k --since "$START_TS" --no-pager 2>/dev/null |
    grep -viE 'NVRM|Xid' |
    grep -icE 'amdgpu.*(reset|timeout|hang)|ring .*timeout|kprobe missed|p2p_force.*(failed|error)|AER.*(fatal|uncorrected)|Oops|BUG:|general protection'
}

echo "ts,tainted,module,kfd_links,temp_mc,power_w,aer_corr,aer_fatal,link,kernel_events" > "$OUT"

while :; do
  now=$(date +%s)
  ts=$(date '+%F %T')
  tainted=$(cat /proc/sys/kernel/tainted 2>/dev/null || echo -1)
  module=$([ -d /sys/module/p2p_force ] && echo 1 || echo 0)
  links=$(kfd_links)
  temp=$(gpu_max_temp)
  power=$(gpu_power_w)
  corr=$(aer_sum aer_dev_correctable)
  fatal=$(aer_sum aer_dev_fatal)
  link=$(link_state)
  ev=$(kernel_events)

  echo "$ts,$tainted,$module,$links,$temp,$power,$corr,$fatal,\"$link\",$ev" >> "$OUT"

  [ "$module" = 1 ]           || echo "[ALERT] $ts p2p_force 模块未加载"
  [ "$links" -ge 2 ]          || echo "[ALERT] $ts KFD p2p 链路数=$links（期望 >=2）"
  [ "$temp" -le $TEMP_MAX_MC ]|| echo "[ALERT] $ts GPU 温度 ${temp}mc 超过 ${TEMP_MAX_MC}mc"
  [ "$fatal" = 0 ]            || echo "[ALERT] $ts AER fatal 计数=$fatal"
  [ "$corr" -le $AER_CORR_MAX ] || echo "[ALERT] $ts AER correctable 计数=$corr 超过 $AER_CORR_MAX"
  [ "$ev" = 0 ]               || echo "[ALERT] $ts 内核异常事件 $ev 条（journalctl -k --since \"$START_TS\" 查看）"

  if [ "$DURATION" -gt 0 ] && [ $((now - START_EPOCH)) -ge "$DURATION" ]; then
    break
  fi
  sleep "$INTERVAL"
done

echo "[DONE] CSV 已写入 $OUT"
