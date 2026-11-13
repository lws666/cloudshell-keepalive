#!/usr/bin/env bash
# ka.sh — Cloud Shell + DSH 保活守护 (v3)
#
# ═══════ 机制（已在本机实测确认）═══════
# 1. Cloud Shell 的 idle 判定看 devshell websocket 上有没有数据流。
#    tmux 只把「attached client 所在 session 的 active window 的 active pane」
#    的输出推给前端，所以心跳必须写那个 pane 的 pty 输出端：
#        printf <字节> > /proc/<pane_pid>/fd/1
#    实测: 写入后 tmux capture-pane 能读到字节、window_activity 时间戳推进。
# 2. 心跳载荷 = 零宽空格 U+200B (e2 80 8b)，不占列宽、不换行、无可见痕迹。
# 3. 防污染: 只在 pane 前台是 shell 时写。若前台是 vim/less/htop 等全屏程序，
#    该轮跳过，避免搅乱光标。
# 4. 服务自愈: 3080(DSH) / 3081(Origin 改写代理) 掉线自动拉起，防 preview 502。
# 5. preview 自请求: 每 5 轮对 https://PORT-WEB_HOST/ 发一次请求，维持边缘链路热态。
#
# ═══════ 边界（必须知道）═══════
# - 心跳只在「浏览器上有一个 Cloud Shell 终端页签」时才有意义。页签全关 =
#   没有 websocket，写 pty 无人接收。此时守护仍会跑（保服务），但 Cloud Shell
#   的 idle 计时由 Google 侧决定，本地无能为力。
# - 12h 会话硬上限 / 每周 50h 配额：本地无法绕过。本脚本按 --hours 自退，5h 安全。
# - 心跳只在终端页签可见范围生效，标签页在后台（background tab）也照样收数据，
#   不需要页签在前台。
#
# ═══════ 用法 ═══════
#   ka.sh                     前台跑 5h（调试）
#   ka.sh --hours 8           自定义时长
#   ka.sh --interval 45       心跳间隔秒
#   ka.sh --no-heal           只心跳不自愈
#   ka.sh --any-window        无 client 时也向所有 session 的 active pane 写
#   ka.sh --dry-run           跑 3 轮自检退出
#
# 文件: ka.log (≤256KB 自动滚动) | ka.status | ka.lock

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$HERE/ka.log"; STATUS="$HERE/ka.status"
DSH_PORT="${DSH_PORT:-3080}"; PROXY_PORT="${DSH_PROXY_PORT:-3081}"
START_SH="$HOME/.local/bin/dsh-start.sh"
PROXY_JS="$HOME/.local/bin/rewrite-proxy.mjs"
LOG_MAX=262144; LOG_KEEP=131072
ZWSP=$'\xe2\x80\x8b'

HOURS=5; INTERVAL=45; HEAL=1; ANYWIN=0; DRY=0

while (($#)); do
  case "$1" in
    --hours)      HOURS="${2:-5}";     shift 2 ;;
    --interval)   INTERVAL="${2:-45}"; shift 2 ;;
    --no-heal)    HEAL=0;              shift ;;
    --any-window) ANYWIN=1;            shift ;;
    --dry-run)    DRY=1;               shift ;;
    -h|--help)    sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

# ── 单实例：PID 文件（不用 flock —— 子进程会继承锁 fd，父进程死后锁不释放）──
PIDF="$HERE/ka.pid"
if [[ -f "$PIDF" ]]; then
  old=$(cat "$PIDF" 2>/dev/null || true)
  if [[ -n "$old" ]] && kill -0 "$old" 2>/dev/null; then
    # 确认那个 pid 确实是 ka.sh，防止 pid 复用误判
    if tr '\0' ' ' < "/proc/$old/cmdline" 2>/dev/null | grep -q "ka\.sh"; then
      echo "[ka] 已有实例 pid=$old 在跑，退出" >&2
      exit 1
    fi
  fi
fi
echo $$ > "$PIDF"
trap 'rm -f "$PIDF"' EXIT

log()  { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }
say()  { log "$*"; printf '[ka] %s\n' "$*"; }
rotate_log() {
  local sz; sz=$(stat -c%s "$LOG" 2>/dev/null || echo 0)
  (( sz > LOG_MAX )) && { tail -c "$LOG_KEEP" "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"; }
}
port_alive() { ss -ltn 2>/dev/null | grep -q ":$1 "; }
http_code() {
  local o; o=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "$1" 2>/dev/null)
  printf '%s' "${o:-000}"
}

# ═════════ 心跳目标：client 正在看的 pane ═════════
# 输出: <target>\t<pane_pid>\t<front_cmd>\t<client_tty>
hb_targets() {
  local sess win pane pid cmd tty
  if [[ -n "$(tmux list-clients 2>/dev/null)" ]]; then
    tmux list-clients -F '#{client_session}|#{client_tty}' 2>/dev/null |
    while IFS='|' read -r sess tty; do
      win=$(tmux display-message -p -t "$sess" '#{window_index}' 2>/dev/null) || continue
      pane=$(tmux display-message -p -t "$sess:$win" '#{pane_index}' 2>/dev/null) || continue
      pid=$(tmux display-message -p -t "$sess:$win.$pane" '#{pane_pid}' 2>/dev/null) || continue
      cmd=$(tmux display-message -p -t "$sess:$win.$pane" '#{pane_current_command}' 2>/dev/null)
      [[ -n "$pid" ]] && printf '%s:%s.%s\t%s\t%s\t%s\n' "$sess" "$win" "$pane" "$pid" "$cmd" "$tty"
    done
  elif (( ANYWIN )); then
    tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}|#{pane_pid}|#{pane_current_command}|#{window_active}' 2>/dev/null |
    awk -F'|' '$4==1 {print $1"\t"$2"\t"$3"\tnone"}'
  fi
}

# 安全前台命令白名单（只有这些才写 pty，避免污染全屏 TUI）
is_safe_cmd() {
  case "$1" in
    bash|sh|zsh|dash|-bash|-sh|node|python3|python|sleep|tail|cat|ka.sh) return 0 ;;
    *) return 1 ;;
  esac
}

hb_write_pane() {
  local pid=$1
  { printf '%s' "$ZWSP" > "/proc/$pid/fd/1"; } 2>/dev/null && return 0
  local cpid; cpid=$(pgrep -P "$pid" 2>/dev/null | head -1)
  [[ -n "$cpid" ]] && { printf '%s' "$ZWSP" > "/proc/$cpid/fd/1"; } 2>/dev/null && return 0
  return 1
}

heartbeat() {
  local rows n=0 ok=0 skip=0 t pid cmd tty
  rows=$(hb_targets)
  if [[ -z "$rows" ]]; then
    # 没有浏览器 client attach：退化到所有 session 的 active pane。
    # 推不到前端，但刷新 tmux 内部 activity，且页签重连时会重绘。
    rows=$(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}|#{pane_pid}|#{pane_current_command}' 2>/dev/null |
           awk -F'|' '{print $1"\t"$2"\t"$3"\tnone"}')
    [[ -n "$rows" ]] && log "hb-degrade 无 client，写所有 active pane"
  fi
  if [[ -z "$rows" ]]; then log "hb-skip 无任何 tmux pane"; return 1; fi
  while IFS=$'\t' read -r t pid cmd tty; do
    [[ -z "$pid" ]] && continue
    n=$((n+1))
    if ! is_safe_cmd "$cmd"; then
      skip=$((skip+1)); log "hb-skip $t 前台=$cmd（非 shell，跳过以免污染）"; continue
    fi
    if hb_write_pane "$pid"; then ok=$((ok+1)); log "hb-ok $t pid=$pid cmd=$cmd"
    else log "hb-fail $t pid=$pid"; fi
  done <<< "$rows"
  log "hb-summary targets=$n ok=$ok skip=$skip"
  (( ok > 0 ))
}

# ═════════ 自愈 ═════════
ensure_dsh() {
  local code i
  code=$(http_code "http://127.0.0.1:$DSH_PORT/")
  [[ "$code" != "000" ]] && return 0
  if port_alive "$DSH_PORT"; then
    say "3080 监听但无 HTTP 响应(code=$code)，等下轮，不抢端口"; return 1
  fi
  say "3080 未监听 → 拉起 DSH"
  [[ -x "$START_SH" ]] || { say "缺少 $START_SH"; return 1; }
  setsid nohup bash "$START_SH" --no-clean >> "$HERE/dsh-restart.log" 2>&1 < /dev/null &
  for i in $(seq 1 40); do
    sleep 3
    code=$(http_code "http://127.0.0.1:$DSH_PORT/")
    [[ "$code" != "000" ]] && { say "DSH 就绪(code=$code, $((i*3))s)"; return 0; }
  done
  say "DSH 120s 未就绪"; return 1
}

ensure_proxy() {
  local code
  code=$(http_code "http://127.0.0.1:$PROXY_PORT/")
  [[ "$code" != "000" ]] && return 0
  port_alive "$PROXY_PORT" && return 0
  [[ -f "$PROXY_JS" ]] || { say "缺少 $PROXY_JS"; return 1; }
  say "3081 未监听 → 拉起 rewrite proxy"
  setsid nohup node "$PROXY_JS" >> "$HERE/proxy-restart.log" 2>&1 < /dev/null &
  sleep 2
}

# preview 边缘热态（带 Host 改写，走 3081 避免 403）
preview_touch() {
  [[ -z "${WEB_HOST:-}" ]] && { log "preview-skip 无 WEB_HOST"; return 1; }
  local url="https://${PROXY_PORT}-${WEB_HOST}/"
  local code; code=$(http_code "$url")
  log "preview-touch $url -> $code"
  return 0
}

gcloud_touch() {
  gcloud config get-value core/account >/dev/null 2>&1 || true
  gcloud config get-value core/project >/dev/null 2>&1 || true
}

write_status() {
  local now up nc
  now=$(date +%s); up=$(( now - START_TS ))
  nc=$(tmux list-clients 2>/dev/null | wc -l)
  {
    echo "state=$STATE"
    echo "start=$(date -d "@$START_TS" '+%F %T')"
    echo "deadline=$(date -d "@$END_TS" '+%F %T')"
    echo "elapsed_min=$(( up / 60 ))"
    echo "remaining_min=$(( (END_TS - now) / 60 ))"
    echo "interval=$INTERVAL  heal=$HEAL"
    echo "dsh_$DSH_PORT=$(http_code "http://127.0.0.1:$DSH_PORT/")"
    echo "proxy_$PROXY_PORT=$(http_code "http://127.0.0.1:$PROXY_PORT/")"
    echo "preview=${WEB_HOST:-none}"
    echo "tmux_clients=$nc"
    echo "targets=$(hb_targets | cut -f1 | tr '\n' ' ')"
    echo "hb_ok=$(grep -c 'hb-ok' "$LOG" 2>/dev/null || true)"
    echo "hb_skip=$(grep -c 'hb-skip' "$LOG" 2>/dev/null || true)"
    echo "pid=$$"
  } > "$STATUS"
}

START_TS=$(date +%s)
# HOURS 允许小数（如 0.05）；bash 算术只吃整数，用 awk 算秒数
if [[ -n "${KA_DEADLINE:-}" ]]; then
  END_TS="$KA_DEADLINE"
else
  DUR_SEC=$(awk -v h="$HOURS" 'BEGIN{printf "%d", h*3600}')
  [[ -z "$DUR_SEC" || "$DUR_SEC" -lt 1 ]] && DUR_SEC=60
  END_TS=$(( START_TS + DUR_SEC ))
fi
STATE=running

log "================ ka v3 start ================"
say "保活 ${HOURS}h 间隔 ${INTERVAL}s 自愈 $([[ $HEAL == 1 ]] && echo on || echo off) anywin=$ANYWIN pid $$"
say "截止 $(date -d "@$END_TS" '+%F %T')"
say "目标 $(hb_targets | cut -f1 | tr '\n' ' ')"
write_status   # 启动即刷新状态，不等 tick%4

tick=0; fail_dsh=0
while :; do
  now=$(date +%s)
  (( now >= END_TS )) && { say "到达时限，收尾退出"; break; }
  tick=$(( tick + 1 ))

  heartbeat || true

  if (( HEAL )); then
    if ensure_dsh; then fail_dsh=0; else fail_dsh=$((fail_dsh+1)); fi
    if (( fail_dsh >= 5 )); then
      say "DSH 连续 5 轮不就绪 → 清 0 字节陈旧锁"
      find "$HOME/.dsh" -maxdepth 2 -name '*.lock' -size 0 -mmin +1 -delete 2>/dev/null
      fail_dsh=0
    fi
    ensure_proxy
  fi

  (( tick % 7 == 0 ))  && gcloud_touch
  (( HEAL )) && preview_touch

  if (( tick % 4 == 0 )); then write_status; fi
  if (( tick % 20 == 0 )); then
    say "巡检 clients=$(tmux list-clients 2>/dev/null | wc -l) local=$(http_code "http://127.0.0.1:$PROXY_PORT/")"
    rotate_log
  fi

  (( DRY && tick >= 3 )) && { say "--dry-run 完成"; break; }
  sleep "$INTERVAL"
done

STATE=stopped; write_status
log "================ ka stop (运行 $(( ($(date +%s) - START_TS) / 60 ))min) ================"
say "已停止。日志 $LOG"
exit 0
