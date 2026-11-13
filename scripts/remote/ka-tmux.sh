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
INTERVAL_MIN="${INTERVAL_MIN:-20}"

http_code() {
  local o; o=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "$1" 2>/dev/null)
  printf '%s' "${o:-000}"
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

    # 顺带迁移仍绑在用户终端上的代理（只在无活跃连接时做，避免 502）
    local psid_mine psid_proxy conns
    psid_mine=$(ps -o sid= -p $$ | tr -d ' ')
    psid_proxy=$(ps -eo pid,sid,cmd | awk '/rewrite-proxy\.mjs/ && !/awk/{print $2; exit}')
    conns=$(ss -tn state established 2>/dev/null | grep -c ":3081" || true)
    if [[ -n "$psid_proxy" && "$psid_proxy" != "$psid_mine" ]]; then
      if (( ${conns:-0} == 0 )); then
        printf '%s 代理 SID=%s ≠ tmux=%s 且无连接，迁移\n' \
          "$(date '+%F %T')" "$psid_proxy" "$psid_mine" >> "$LOG"
        local ppid
        ppid=$(ss -ltnp 2>/dev/null | grep -E "127\.0\.0\.1:3081\b" \
               | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)
        [[ -n "$ppid" ]] && kill "$ppid" 2>/dev/null && sleep 2
        # 用 setsid 让代理自带会话：worker 重启/退出都不影响它
        # （setsid 只保证不随 worker 死，仍独立于用户终端）
        setsid nohup node "$HOME/.local/bin/rewrite-proxy.mjs" \
          >> "$HOME/.cache/dsh/proxy.log" 2>&1 < /dev/null &
        sleep 3
        printf '%s 代理已迁移 SID=%s\n' \
          "$(date '+%F %T')" \
          "$(ps -eo pid,sid,cmd | awk '/rewrite-proxy\.mjs/ && !/awk/{print $2; exit}')" >> "$LOG"
      else
        printf '%s 代理 SID=%s 仍绑用户终端，但有 %s 个连接，跳过迁移\n' \
          "$(date '+%F %T')" "$psid_proxy" "$conns" >> "$LOG"
      fi
    fi

    printf '%s 前=%s 后=%s dsh_sid=%s proxy_sid=%s\n' \
      "$(date '+%F %T')" "$before" "$after" \
      "$(ps -eo pid,sid,cmd | awk '/bin\.js web/ && !/awk/{print $2; exit}')" \
      "$(ps -eo pid,sid,cmd | awk '/rewrite-proxy\.mjs/ && !/awk/{print $2; exit}')" >> "$LOG"

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
      declare -f http_code
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
