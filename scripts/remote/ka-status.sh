#!/usr/bin/env bash
# ka-status.sh — 一屏看保活状态
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== ka.status ==="
cat "$HERE/ka.status" 2>/dev/null || echo "(无状态文件，未启动过)"

echo
echo "=== 进程 ==="
pgrep -af "ka(-supervise)?\.sh" | grep -v grep || echo "(无守护进程)"

echo
echo "=== tmux ==="
tmux list-clients -F 'client=#{client_name} tty=#{client_tty} session=#{client_session} last_activity=#{client_activity}' 2>/dev/null || true
tmux list-windows -a -F '#{session_name}:#{window_index} #{window_name} #{pane_current_command}' 2>/dev/null || true

echo
echo "=== 最近日志 ==="
tail -n 12 "$HERE/ka.log" 2>/dev/null || echo "(无日志)"

echo
echo "=== 心跳计数 ==="
hb=$(grep -c ' hb [0-9]' "$HERE/ka.log" 2>/dev/null || true)
echo "hb=${hb:-0}"
