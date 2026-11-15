#!/usr/bin/env bash
# ka-tmux.sh — 在 tmux 里常驻保活（Cloud Shell 下唯一稳定的载体）
#
# ═══ 为什么必须用 tmux ═══
# 实测三种后台方式在 Cloud Shell 里的存活能力：
#
#   方式                          进程 SID        终端关闭后
#   ────────────────────────────  ─────────────  ──────────
#   nohup cmd &                   原 shell       ✗ 被进程组清理
#   setsid nohup cmd &            自己           ✗ 仍随会话回收
#   tmux new-session -d + 里面跑   自己(tmux托管)  ✓ 受 tmux server 托管
#
# tmux server 是独立于任何终端的长生命周期进程，它托管的 pane 里跑的
# 进程不会因为「你关掉浏览器终端」而被清理。这是 Cloud Shell 里唯一
# 真正能扛住会话回收的方式。
#
# ═══ 它做什么 ═══
# 在名为 dsh-keep 的 tmux 会话里循环：
#   每 INTERVAL 分钟执行一次 ~/dsh-cloudshell-start.sh
# 脚本自身幂等（已运行则跳过），所以重复调用很安全。
#
# 用法:
#   ka-tmux.sh start            启动（默认 20 分钟一次，跟 tmux 会话同寿命）
#   ka-tmux.sh stop             停止
#   ka-tmux.sh status           查看状态
#   ka-tmux.sh logs             跟踪日志
#   ka-tmux.sh once             立刻执行一次（无需常驻）
#
# 日志: ~/keepalive/tmux-keep.log

set -uo pipefail

SESSION="dsh-keep"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$HERE/tmux-keep.log"
START_SH="$HOME/dsh-cloudshell-start.sh"
INTERVAL_MIN="${INTERVAL_MIN:-5}"

http_code() {
  local o; o=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "$1" 2>/dev/null)
  printf '%s' "${o:-000}"
}

# 按进程名精确检测（不能用 pgrep -f：会匹配到执行命令的 shell 自身）
proc_alive() {
  local name=$1 d
  for d in /proc/[0-9]*; do
    [ -r "$d/comm" ] || continue
    [ "$(cat "$d/comm" 2>/dev/null)" = "$name" ] && return 0
  done
  return 1
}

# 按监听端口反查 pid
pid_on_port() {
  ss -ltnp 2>/dev/null | grep -E "127\.0\.0\.1:$1\b" \
    | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2
}

# 代理健康 = 进程在 + 3081 有 HTTP 应答
# 只查进程不够：曾实测 kill(SIGTERM) 后进程滞留为 S<l+ 但功能已死，返回 530/无响应
# 注：不要用 proc_alive node —— 实测 node 进程的 comm 是 "node-MainThread"，
#     精确比对会永远失败。改用「端口有进程 + HTTP 有应答」双判据，更直接。
proxy_healthy() {
  [ -n "$(pid_on_port 3081)" ] || return 1
  local c; c=$(http_code "http://127.0.0.1:3081/")
  [ "$c" != "000" ]
}

# 隧道健康 = cloudflared 进程在 + 域名能应答
# 只查进程不够：进程假死时隧道返回 530（实测）
tunnel_healthy() {
  proc_alive cloudflared || return 1
  [ -s "$HOME/.cloudflared/tunnel-token" ] || return 0  # 没配隧道就不算故障
  local c; local th="${TUNNEL_HOST:-}"
  [ -z "$th" ] && [ -s "$HOME/.cloudflared/hostname" ] && th=$(head -1 "$HOME/.cloudflared/hostname" | tr -d '[:space:]')
  th="${th:-dsh.example.com}"
  c=$(http_code "https://$th/login")
  [ "$c" != "000" ] && [ "$c" != "530" ]
}

# 重启代理（detached，不随 worker 死）
restart_proxy() {
  local p; p=$(pid_on_port 3081)
  [ -n "$p" ] && kill -9 "$p" 2>/dev/null && sleep 1
  # 清掉可能滞留的代理进程（按 cmdline 匹配，comm 不可靠）
  local d cl
  for d in /proc/[0-9]*; do
    [ -r "$d/cmdline" ] || continue
    cl=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)
    case "$cl" in *rewrite-proxy.mjs*) kill -9 "${d#/proc/}" 2>/dev/null ;; esac
  done
  sleep 1
  setsid nohup node "$HOME/.local/bin/rewrite-proxy.mjs" \
    >> "$HOME/.cache/dsh/proxy.log" 2>&1 < /dev/null &
  sleep 3
}

# 重启隧道
restart_tunnel() {
  local d
  for d in /proc/[0-9]*; do
    [ -r "$d/comm" ] || continue
    [ "$(cat "$d/comm" 2>/dev/null)" = "cloudflared" ] && kill -9 "${d#/proc/}" 2>/dev/null
  done
  sleep 2
  [ -x "$HOME/.local/bin/cloudflared" ] || return 1
  setsid nohup "$HOME/.local/bin/cloudflared" tunnel --no-autoupdate run \
    --token-file "$HOME/.cloudflared/tunnel-token" \
    >> "$HOME/.cache/dsh/tunnel-named.log" 2>&1 < /dev/null &
  sleep 8
}

# tmux 里的工作循环
worker() {
  local n=0
  while :; do
    n=$((n+1))
    printf '%s ── 第 %d 次 ──\n' "$(date '+%F %T')" "$n" >> "$LOG"
    local before after
    before=$(http_code "http://127.0.0.1:3080/")

    # 关键：这里的命令跑在 tmux pane 里，因此服务继承 tmux 会话，
    # 不继承任何用户终端会话。
    bash "$START_SH" >> "$LOG" 2>&1
    after=$(http_code "http://127.0.0.1:3080/")

    # ── 代理健康检查 + 自愈 ──
    # 不只看进程，还要 3081 能应答；假死（进程在但端口无响应）也会重启
    if ! proxy_healthy; then
      printf '%s [自愈] 代理不健康 → 重启\n' "$(date '+%F %T')" >> "$LOG"
      restart_proxy
      if proxy_healthy; then
        printf '%s [自愈] 代理已恢复 code=%s sid=%s\n' \
          "$(date '+%F %T')" "$(http_code http://127.0.0.1:3081/)" \
          "$(ps -eo pid,sid,cmd | awk '/rewrite-proxy\.mjs/ && !/awk/{print $2; exit}')" >> "$LOG"
      else
        printf '%s [自愈] 代理重启失败\n' "$(date '+%F %T')" >> "$LOG"
      fi
    fi

    # ── 隧道健康检查 + 自愈 ──
    # 进程假死时隧道会返回 530，只看进程判断不出来
    if ! tunnel_healthy; then
      printf '%s [自愈] 隧道不健康 → 重启\n' "$(date '+%F %T')" >> "$LOG"
      restart_tunnel
      if tunnel_healthy; then
        printf '%s [自愈] 隧道已恢复\n' "$(date '+%F %T')" >> "$LOG"
      else
        printf '%s [自愈] 隧道重启失败（继续观察）\n' "$(date '+%F %T')" >> "$LOG"
      fi
    fi

    printf '%s 前=%s 后=%s 代理=%s 隧道=%s dsh_sid=%s\n' \
      "$(date '+%F %T')" "$before" "$after" \
      "$(http_code http://127.0.0.1:3081/)" \
      "$(http_code "https://$( [ -s "$HOME/.cloudflared/hostname" ] && head -1 "$HOME/.cloudflared/hostname" | tr -d "[:space:]" || echo dsh.example.com )/login")" \
      "$(ps -eo pid,sid,cmd | awk '/bin\.js web/ && !/awk/{print $2; exit}')" >> "$LOG"

    # 睡眠（分段，便于 stop 快速生效）
    local slept=0
    while (( slept < INTERVAL_MIN * 60 )); do
      sleep 10; slept=$((slept+10))
    done
  done
}

case "${1:-start}" in
  start)
    if [[ ! -f "$START_SH" ]]; then
      echo "✗ 缺少 $START_SH" >&2; exit 1
    fi
    touch "$LOG"
    if tmux has-session -t "$SESSION" 2>/dev/null; then
      echo "[ka-tmux] 会话 $SESSION 已存在，先停止"
      tmux kill-session -t "$SESSION" 2>/dev/null
      sleep 1
    fi
    # 把 worker 函数写进一个临时脚本，供 tmux 调用
    WORKER="$HERE/.tmux-worker.sh"
    {
      echo '#!/usr/bin/env bash'
      echo 'set -uo pipefail'
      # 必须把所有被 worker 调用的函数都序列化进去，
      # 否则 worker 脚本里缺定义 → 检测恒失败 → 每轮误报「自愈」。
      # （踩过：新增的 pid_on_port/proxy_healthy/tunnel_healthy 漏在这里）
      declare -f http_code
      declare -f proc_alive
      declare -f pid_on_port
      declare -f proxy_healthy
      declare -f tunnel_healthy
      declare -f restart_proxy
      declare -f restart_tunnel
      declare -f worker
      echo "LOG='$LOG'"
      echo "START_SH='$START_SH'"
      echo "INTERVAL_MIN=$INTERVAL_MIN"
      echo 'worker'
    } > "$WORKER"
    chmod +x "$WORKER"

    tmux new-session -d -s "$SESSION" -c "$HERE" "bash '$WORKER'"
    sleep 3
    if tmux has-session -t "$SESSION" 2>/dev/null; then
      echo "[ka-tmux] 已启动，会话=$SESSION 间隔=${INTERVAL_MIN}min"
      echo "[ka-tmux] 日志: $LOG"
      echo "[ka-tmux] 验证隔离:"
      echo "  我的 SID      = $(ps -o sid= -p $$ | tr -d ' ')"
      echo "  3080 进程 SID = $(ps -eo pid,sid,cmd | awk '/bin\.js web/ && !/awk/{print $2; exit}')"
      echo "  3080 应答     = $(http_code http://127.0.0.1:3080/)"
    else
      echo "✗ 启动失败" >&2; tail -10 "$LOG"; exit 1
    fi
    ;;

  stop)
    if tmux has-session -t "$SESSION" 2>/dev/null; then
      tmux kill-session -t "$SESSION" && echo "[ka-tmux] 已停止会话 $SESSION"
    else
      echo "[ka-tmux] 会话 $SESSION 不存在"
    fi
    ;;

  status)
    echo "=== tmux 会话 ==="
    tmux has-session -t "$SESSION" 2>/dev/null \
      && echo "  $SESSION: 运行中" || echo "  $SESSION: 未运行"
    echo "=== 服务 ==="
    echo "  3080=$(http_code http://127.0.0.1:3080/)  3081=$(http_code http://127.0.0.1:3081/)"
    echo "=== 进程会话归属 ==="
    echo "  我的 SID      = $(ps -o sid= -p $$ | tr -d ' ')"
    ps -eo pid,sid,etime,cmd | awk '/bin\.js web|rewrite-prox/ && !/awk/ {printf "  PID=%s SID=%s UP=%s\n",$1,$2,$3}'
    echo "=== 最近日志 ==="
    tail -6 "$LOG" 2>/dev/null || echo "  (无)"
    ;;

  logs)
    exec tail -f "$LOG"
    ;;

  once)
    echo "[ka-tmux] 立即执行一次"
    bash "$START_SH" 2>&1 | tail -5
    echo "3080=$(http_code http://127.0.0.1:3080/)"
    ;;

  *)
    sed -n '2,30p' "$0"; exit 2 ;;
esac
