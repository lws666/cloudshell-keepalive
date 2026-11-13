#!/usr/bin/env bash
# ka-start.sh — 拉起保活守护（幂等，可反复执行）
#
# 设计要点:
#   * 守护进程用 setsid + nohup 完全脱离终端，不开 tmux 窗口、不抢用户视图、
#     不会因为关窗口/断连被杀。
#   * 心跳由 ka.sh 自己找「浏览器正在看的那个 pane」去写 pty，无须守护进程
#     本身待在 pane 里。
#   * 重复执行只会重启守护，不会叠加多个实例（flock 保证）。

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOURS=5; INTERVAL=45; EXTRA=""
while (($#)); do
  case "$1" in
    --hours)    HOURS="${2:-5}"; shift 2 ;;
    --interval) INTERVAL="${2:-45}"; shift 2 ;;
    --any-window) EXTRA="$EXTRA --any-window"; shift ;;
    *) shift ;;
  esac
done

# 先停旧实例
bash "$HERE/ka-stop.sh" >/dev/null 2>&1 || true

# 等旧实例彻底退出（PID 文件删除 / 进程消失）
for _ in $(seq 1 20); do
  pgrep -f "keepalive/k[a]\.sh" >/dev/null 2>&1 || break
  sleep 0.5
done

# HOURS 允许小数；bash 算术只吃整数，用 awk
DUR_SEC=$(awk -v h="$HOURS" 'BEGIN{printf "%d", h*3600}')
[[ -z "$DUR_SEC" || "$DUR_SEC" -lt 1 ]] && DUR_SEC=60
DEADLINE=$(( $(date +%s) + DUR_SEC ))
mkdir -p "$HERE"

KA_DEADLINE="$DEADLINE" setsid nohup bash "$HERE/ka.sh" \
  --hours "$HOURS" --interval "$INTERVAL" $EXTRA \
  >> "$HERE/daemon.out" 2>&1 < /dev/null &

sleep 2
if pgrep -f "keepalive/k[a]\.sh" >/dev/null 2>&1; then
  echo "[ka-start] 已启动 pid=$(pgrep -f 'keepalive/k[a]\.sh' | tr '\n' ' ')"
  echo "[ka-start] 时长 ${HOURS}h  间隔 ${INTERVAL}s  截止 $(date -d "@$DEADLINE" '+%F %T')"
  echo "[ka-start] 状态: bash $HERE/ka-status.sh"
else
  echo "[ka-start] 启动失败，看 $HERE/daemon.out" >&2
  tail -5 "$HERE/daemon.out" 2>/dev/null
  exit 1
fi
