#!/usr/bin/env bash
# ka-stop.sh — 停止保活守护（只杀自己的守护，不碰 tmux 会话/窗口）
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

n=0
for p in $(pgrep -f "keepalive/k[a]\.sh" 2>/dev/null); do
  kill "$p" 2>/dev/null && n=$((n+1))
done
for p in $(pgrep -f "keepalive/ka-supervis[e]\.sh" 2>/dev/null); do
  kill "$p" 2>/dev/null && n=$((n+1))
done

# 给 2 秒优雅退出，再补刀
sleep 1
pgrep -f "keepalive/k[a]\.sh" >/dev/null 2>&1 && pkill -9 -f "keepalive/k[a]\.sh" 2>/dev/null

rm -f "$HERE/ka.pid" 2>/dev/null || true
sed -i 's/^state=running/state=stopped/' "$HERE/ka.status" 2>/dev/null || true
echo "[ka-stop] 已停止 $n 个进程（tmux 会话未受影响）"
