#!/usr/bin/env bash
# 双卡占用权协调器：工作态（TP/Comfy/vLLM/SGLang）与日常态（常驻推理服务）互斥，
# 工作态结束自动恢复常驻服务。
# 参考实现：默认服务为 strata.service，可用环境变量替换：
#   GPU_OWNER_BASE / GPU_OWNER_CTL / GPU_OWNER_UNIT / GPU_OWNER_HEALTH_URL / GPU_OWNER_MODE_FILE
# 用法：
#   gpu-owner.sh status
#   gpu-owner.sh acquire <job> [--pid PID] [--min-free-mib N] [--ttl S]
#   gpu-owner.sh holder <pid>
#   gpu-owner.sh release [--no-restore] [--reason TEXT]
#   gpu-owner.sh user-stop            # 用户显式 stop/exit：取消自动恢复，保留日常态
#   gpu-owner.sh pre-start            # 启动服务前清工作态；若工作态任务仍活着则拒绝
#   gpu-owner.sh guard                # systemd ExecStartPre：工作态/占用中则拒绝拉起
#   gpu-owner.sh watchdog-once        # 看门狗单次巡检：持有者消失/超时则自动恢复
set -uo pipefail

BASE="${GPU_OWNER_BASE:-${HOME:-/home/jay}/strata}"
export HOME="${HOME:-/home/jay}"
GM="${GPU_OWNER_SELF:-$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")}"
CTL="${GPU_OWNER_CTL:-$BASE/scripts/strata-ctl.sh}"
UNIT="${GPU_OWNER_UNIT:-strata.service}"
HEALTH_URL="${GPU_OWNER_HEALTH_URL:-http://127.0.0.1:8080/health}"
MODE_FILE="${GPU_OWNER_MODE_FILE:-$BASE/.strata-mode}"
STATE="$BASE/.gpu-owner"
MARK="$BASE/.worklock"
LOCKF="$BASE/.gpu-owner.lock"
LOG="$BASE/logs/mode.log"
BOOTID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)
VRAM_FREE_MIB=${VRAM_FREE_MIB:-1500}
MIN_FREE_MIB=${MIN_FREE_MIB:-8192}
DEFAULT_TTL=${DEFAULT_TTL:-43200}

mkdir -p "$BASE/logs" 2>/dev/null || true

say()  { printf '%s\n' "$*"; }
log()  { printf '%s %s %s\n' "$(date '+%F %T')" "$1" "$2" >> "$LOG" 2>/dev/null || true; }
die()  { printf '错误：%s\n' "$*" >&2; exit 1; }

strata_active() { systemctl is-active --quiet "$UNIT"; }
strata_healthy() { curl -fsS --max-time 2 "$HEALTH_URL" >/dev/null 2>&1; }
strata_mode() { cat "$MODE_FILE" 2>/dev/null || echo dual; }

state_get() { # state_get <key> → 值（缺省空）
  [ -f "$STATE" ] || return 0
  awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$STATE"
}

state_write() { # state_write key=value ...
  local tmp="$STATE.tmp.$$" kv
  : > "$tmp"
  # 先在旧文件里保留未更新的键
  [ -f "$STATE" ] && grep -vE "^($(printf '%s|' "$@" | sed 's/|=.*$//')" "$STATE" >> "$tmp" 2>/dev/null || true
  for kv in "$@"; do printf '%s\n' "$kv" >> "$tmp"; done
  if ! grep -q '^owner=' "$tmp"; then printf 'owner=daily\n' >> "$tmp"; fi
  mv -f "$tmp" "$STATE"
}

state_clear() {
  rm -f "$MARK" 2>/dev/null || true
  printf 'owner=daily\nsince=%s\nboot=%s\nrestore_running=0\n' "$(date +%s)" "$BOOTID" > "$STATE"
}

pid_alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

mem_available_mib() {
  awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0
}

vram_free_ok() {
  local used f
  for f in /sys/class/drm/card*/device/mem_info_vram_used; do
    [ -f "$f" ] || continue
    grep -q 0x1002 "$(dirname "$f")/vendor" 2>/dev/null || continue
    used=$(( $(cat "$f" 2>/dev/null || echo 0) / 1048576 ))
    [ "$used" -lt "$VRAM_FREE_MIB" ] || return 1
  done
  return 0
}

wait_vram_free() {
  local t=0 timeout=${1:-120}
  while :; do
    vram_free_ok && return 0
    [ "$t" -ge "$timeout" ] && return 1
    sleep 2; t=$((t + 2))
  done
}

show_vram() {
  local f used total card
  for f in /sys/class/drm/card*/device; do
    [ -f "$f/mem_info_vram_used" ] || continue
    grep -q 0x1002 "$f/vendor" 2>/dev/null || continue
    card=$(basename "$(dirname "$f")")
    used=$(( $(cat "$f/mem_info_vram_used" 2>/dev/null || echo 0) / 1048576 ))
    total=$(( $(cat "$f/mem_info_vram_total" 2>/dev/null || echo 0) / 1048576 ))
    printf '%s %s/%sMiB ' "$card" "$used" "$total"
  done
  printf '\n'
}

# ---------- 子命令 ----------
cmd_status() {
  local owner job pid since restore rm ttl
  owner=$(state_get owner); owner=${owner:-daily}
  job=$(state_get job); pid=$(state_get pid); since=$(state_get since)
  restore=$(state_get restore_running); rm=$(state_get restore_mode); ttl=$(state_get ttl)
  say "占用权：$owner$( [ "$owner" = work ] && printf '（job=%s pid=%s）' "${job:-?}" "${pid:-?}" )"
  say "Strata：$(strata_active && echo 运行中 || echo 未运行)$( strata_healthy && echo ' / 接口就绪' || true )  模式：$(strata_mode)"
  if [ "$owner" = work ]; then
    say "恢复策略：$( [ "${restore:-0}" = 1 ] && echo "任务结束后自动启动 Strata（${rm:-dual}）" || echo '不自动恢复' )"
    say "占用起始：$( [ -n "${since:-}" ] && date -d "@$since" '+%F %T' 2>/dev/null || echo '?')  TTL=${ttl:-$DEFAULT_TTL}s"
  fi
  say "显存：$(show_vram)"
  say "内存：可用 $(mem_available_mib) MiB"
}

cmd_acquire() {
  local job=${1:-job}; shift || true
  local pid=${PPID:-$$} pid_set=0 min_free=$MIN_FREE_MIB ttl=$DEFAULT_TTL
  while [ $# -gt 0 ]; do
    case "$1" in
      --pid) pid="$2"; pid_set=1; shift 2 ;;
      --min-free-mib) min_free="$2"; shift 2 ;;
      --ttl) ttl="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  (
    flock 200
    local cur_owner cur_pid cur_job
    cur_owner=$(state_get owner); cur_pid=$(state_get pid); cur_job=$(state_get job)
    if [ "${cur_owner:-daily}" = work ] && pid_alive "${cur_pid:-}"; then
      say "工作态已被占用：job=${cur_job:-?} pid=$cur_pid。结束该任务或先 release。" >&2
      exit 3
    fi
    [ "$pid_set" = 0 ] && pid=$PPID

    local was_running=0 mode
    mode=$(strata_mode)
    if strata_active; then was_running=1; fi

    printf 'owner=work\njob=%s\npid=%s\nsince=%s\nboot=%s\nrestore_running=%s\nrestore_mode=%s\nttl=%s\n' \
      "$job" "$pid" "$(date +%s)" "$BOOTID" "$was_running" "$mode" "$ttl" > "$STATE"
    : > "$MARK"
    log "ACQUIRE" "job=$job pid=$pid strata_was_active=$was_running mode=$mode"

    if [ "$was_running" = 1 ]; then
      say "停止 Strata（保留共享内存 arena，便于恢复）..."
      GPU_MODE_CHILD=1 bash "$CTL" stop || true
    fi

    if ! wait_vram_free 120; then
      log "ACQUIRE-FAIL" "job=$job vram_busy"
      say "显存未回落到 ${VRAM_FREE_MIB} MiB 以下：" >&2
      show_vram >&2
      printf 'restore_running=%s\n' "$was_running" >> "$STATE"
      exit 4
    fi

    local avail
    avail=$(mem_available_mib)
    if [ "$avail" -lt "$min_free" ]; then
      log "ACQUIRE-FAIL" "job=$job mem=${avail}MiB < ${min_free}MiB"
      say "可用内存不足：${avail} MiB < ${min_free} MiB（工作态需要余量）。" >&2
      exit 5
    fi

    log "ACQUIRE-OK" "job=$job vram_free avail=${avail}MiB"
    say "工作态已就绪：job=$job（Strata 已挂起$( [ "$was_running" = 1 ] && echo '，结束将自动恢复' || echo '，原本未运行' )）"
    show_vram
  ) 200>"$LOCKF"
}

cmd_holder() {
  local pid=${1:-}
  [ -n "$pid" ] || die "用法：$0 holder <pid>"
  state_write "pid=$pid"
  log "HOLDER" "pid=$pid"
  say "占用持有者 pid=$pid"
}

cmd_release() {
  local no_restore=0 reason="release"
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-restore) no_restore=1; shift ;;
      --reason) reason="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  (
    flock 200
    local owner restore rm job
    owner=$(state_get owner); restore=$(state_get restore_running); rm=$(state_get restore_mode); job=$(state_get job)
    if [ "${owner:-daily}" != work ]; then
      say "当前不是工作态，无需释放。"
      exit 0
    fi
    printf 'owner=daily\nsince=%s\nboot=%s\nrestore_running=0\n' "$(date +%s)" "$BOOTID" > "$STATE"
    rm -f "$MARK"
    log "RELEASE" "job=${job:-?} reason=$reason restore=$restore mode=${rm:-dual} no_restore=$no_restore"
    if [ "$no_restore" = 0 ] && [ "${restore:-0}" = 1 ]; then
      # 先等残留显存（例如 TP rank1 未退干净）回落，再恢复，避免启动即失败
      if ! wait_vram_free 90; then
        printf 'restore_pending=1\n' >> "$STATE"
        log "RELEASE-DEFER" "job=${job:-?} vram_busy"
        say "显存仍被占用，已登记待恢复；看门狗将自动重试。" >&2
        exit 6
      fi
      say "恢复日常态：启动 Strata（${rm:-dual}）..."
      local out rc
      systemctl reset-failed "$UNIT" 2>/dev/null || true
      out=$(GPU_MODE_CHILD=1 bash "$CTL" start 2>&1); rc=$?
      if [ "$rc" -ne 0 ]; then
        sleep 5
        systemctl reset-failed "$UNIT" 2>/dev/null || true
        out=$(GPU_MODE_CHILD=1 bash "$CTL" start 2>&1); rc=$?
      fi
      if [ "$rc" -ne 0 ]; then
        printf 'restore_pending=1\n' >> "$STATE"
        log "RELEASE-RESTORE-FAIL" "job=${job:-?} rc=$rc out=$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
        say "Strata 恢复失败（已登记待恢复，看门狗将重试）：$out" >&2
        exit 6
      fi
      log "RELEASE-RESTORE-OK" "job=${job:-?}"
    else
      say "已释放占用权（不恢复 Strata）。"
    fi
  ) 200>"$LOCKF"
}

cmd_user_stop() {
  # 用户显式停服：取消自动恢复，清理工作态标记，避免看门狗把服务又拉起来
  local owner
  owner=$(state_get owner)
  state_clear
  log "USER-STOP" "was_owner=${owner:-daily}"
  say "已记录用户停服：取消自动恢复。"
}

cmd_pre_start() {
  local owner pid job
  owner=$(state_get owner); pid=$(state_get pid); job=$(state_get job)
  if [ "${owner:-daily}" = work ]; then
    if pid_alive "${pid:-}"; then
      say "工作态占用中（job=${job:-?} pid=$pid），拒绝启动 Strata。请先结束任务或执行 gpu-mode.sh release。" >&2
      exit 3
    fi
    log "STALE-CLEAR" "job=${job:-?} pid=${pid:-?}"
    state_clear
    say "检测到已结束的工作态（job=${job:-?}），已清理并继续。"
  fi
  rm -f "$MARK" 2>/dev/null || true
  exit 0
}

cmd_guard() {
  local owner pid job boot
  owner=$(state_get owner); pid=$(state_get pid); job=$(state_get job); boot=$(state_get boot)
  if [ "${owner:-daily}" != work ]; then
    rm -f "$MARK" 2>/dev/null || true
    exit 0
  fi
  if [ "${boot:-}" != "$BOOTID" ]; then
    log "GUARD-STALE" "job=${job:-?} boot=$boot"
    state_clear
    say "开机清理上一轮遗留的工作态（job=${job:-?}），允许启动。"
    exit 0
  fi
  if pid_alive "${pid:-}"; then
    say "工作态占用中（job=${job:-?} pid=$pid），跳过 Strata 启动。" >&2
    exit 1
  fi
  log "GUARD-STALE" "job=${job:-?} pid=${pid:-?} not alive"
  state_clear
  exit 0
}

cmd_watchdog() {
  local owner pid job since ttl age pending
  owner=$(state_get owner)
  pending=$(state_get restore_pending)
  if [ "${owner:-daily}" != work ]; then
    # 上次恢复因显存占用失败：这里重试，直到成功
    if [ "${pending:-0}" = 1 ]; then
      if strata_active && strata_healthy; then
        printf 'restore_pending=0\n' >> "$STATE"
        log "WATCHDOG-RESTORE-OK" "pending cleared"
      elif wait_vram_free 10; then
        log "WATCHDOG-RESTORE-RETRY" "pending=1"
        systemctl reset-failed "$UNIT" 2>/dev/null || true
        if GPU_MODE_CHILD=1 bash "$CTL" start >/dev/null 2>&1; then
          printf 'restore_pending=0\n' >> "$STATE"
          log "WATCHDOG-RESTORE-OK" "pending cleared"
        fi
      fi
    fi
    exit 0
  fi
  pid=$(state_get pid); job=$(state_get job); since=$(state_get since); ttl=$(state_get ttl)
  age=$(( $(date +%s) - ${since:-$(date +%s)} ))
  # 启动宽限期内不判断持有者存活，避免任务刚 acquire、引擎尚未拉起时被误回收
  [ "$age" -lt 60 ] && exit 0
  if ! pid_alive "${pid:-}"; then
    log "WATCHDOG" "job=${job:-?} pid=${pid:-?} gone age=${age}s"
    "$GM" release --reason "holder gone" || true
    exit 0
  fi
  if [ "$age" -gt "${ttl:-$DEFAULT_TTL}" ]; then
    log "WATCHDOG-TTL" "job=${job:-?} pid=${pid:-?} age=${age}s"
    "$GM" release --reason "ttl exceeded" || true
  fi
}

case "${1:-status}" in
  status)        cmd_status ;;
  acquire)       shift; cmd_acquire "$@" ;;
  holder)        shift; cmd_holder "$@" ;;
  release)       shift; cmd_release "$@" ;;
  user-stop)     cmd_user_stop ;;
  pre-start)     cmd_pre_start ;;
  guard)         cmd_guard ;;
  watchdog-once) cmd_watchdog ;;
  *)
    printf '用法：%s {status|acquire <job> [--pid PID]|holder <pid>|release [--no-restore]|user-stop|pre-start|guard|watchdog-once}\n' "$0" >&2
    exit 2 ;;
esac
