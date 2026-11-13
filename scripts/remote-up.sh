#!/usr/bin/env bash
# remote-up.sh — CI 在远端 Cloud Shell 里执行的一键启动脚本
#
# 做三件事:
#   1. 拉起 DSH Web (3080) + Origin 改写代理 (3081)，detached 不阻塞
#   2. 等端口真正就绪（不是"进程起来了"就算）
#   3. 拉起 ka.sh 保活守护，持续 HOURS 小时
#
# 关键: dsh-start.sh 结尾是 `exec node`，是前台阻塞进程，必须 setsid 脱离，
#       否则本脚本会被它卡住，永远走不到第 3 步（踩过一次，守护两天没起来）。
#
# 用法:
#   remote-up.sh                      默认 5 小时
#   remote-up.sh --hours 3            自定义时长
#   remote-up.sh --status             只看状态，不启动
#
# 退出码: 0 = DSH 与守护都就绪；1 = 有环节失败（CI 会标红）

set -uo pipefail

HOURS=5
STATUS_ONLY=0
while (($#)); do
  case "$1" in
    --hours)  HOURS="${2:-5}"; shift 2 ;;
    --status) STATUS_ONLY=1; shift ;;
    *) shift ;;
  esac
done

KA_DIR="$HOME/keepalive"
DSH_START="$HOME/.local/bin/dsh-start.sh"
PROXY_JS="$HOME/.local/bin/rewrite-proxy.mjs"
DSH_PORT="${DSH_PORT:-3080}"
PROXY_PORT="${DSH_PROXY_PORT:-3081}"
LOG_DIR="$HOME/.cache/dsh"
mkdir -p "$LOG_DIR" "$KA_DIR"

stamp() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
log()   { printf '[%s] %s\n' "$(stamp)" "$*"; }

http_code() {
  local o
  o=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$1/" 2>/dev/null)
  printf '%s' "${o:-000}"
}

port_alive() { ss -ltn 2>/dev/null | grep -q ":$1 "; }

# ── 状态模式 ──
if (( STATUS_ONLY )); then
  echo "host=$(hostname)  web_host=${WEB_HOST:-none}  time=$(stamp)"
  echo "dsh:$DSH_PORT=$(http_code "$DSH_PORT")  proxy:$PROXY_PORT=$(http_code "$PROXY_PORT")"
  if pid=$(pgrep -f "keepalive/k[a]\.sh" | head -1) && [[ -n "$pid" ]]; then
    echo "ka: running pid=$pid uptime=$(ps -o etime= -p "$pid" | tr -d ' ')"
  else
    echo "ka: not running"
  fi
  [[ -f "$KA_DIR/ka.status" ]] && sed -n '1,8p' "$KA_DIR/ka.status"
  exit 0
fi

log "=== remote-up 开始 (hours=$HOURS) ==="
log "host=$(hostname) WEB_HOST=${WEB_HOST:-none}"

# ═══ 1. DSH Web (3080) ═══
dsh_code=$(http_code "$DSH_PORT")
if [[ "$dsh_code" != "000" ]]; then
  log "DSH 已在运行 code=$dsh_code，跳过启动"
elif port_alive "$DSH_PORT"; then
  log "3080 已监听但无 HTTP 响应，等待 20s 再判断"
  for _ in $(seq 1 20); do
    sleep 1
    [[ "$(http_code "$DSH_PORT")" != "000" ]] && break
  done
fi

if [[ "$(http_code "$DSH_PORT")" == "000" ]]; then
  if [[ ! -x "$DSH_START" ]] && [[ ! -f "$DSH_START" ]]; then
    log "✗ 缺少 $DSH_START"
    exit 1
  fi
  log "拉起 DSH（setsid 脱离，不阻塞本脚本）"
  setsid nohup bash "$DSH_START" --no-clean \
    >> "$LOG_DIR/dsh-ci.log" 2>&1 < /dev/null &

  # 等就绪：最多 180s（首次可能编译 node-pty）
  ready=0
  for i in $(seq 1 60); do
    sleep 3
    c=$(http_code "$DSH_PORT")
    if [[ "$c" != "000" ]]; then
      log "DSH 就绪 code=$c (${i}x3s)"
      ready=1
      break
    fi
  done
  if (( ! ready )); then
    log "✗ DSH 180s 内未就绪，日志尾部:"
    tail -n 10 "$LOG_DIR/dsh-ci.log" 2>/dev/null | sed 's/^/    /'
    exit 1
  fi
fi

# ═══ 2. Origin 改写代理 (3081) ═══
proxy_code=$(http_code "$PROXY_PORT")
if [[ "$proxy_code" == "000" ]] && ! port_alive "$PROXY_PORT"; then
  if [[ -f "$PROXY_JS" ]]; then
    log "拉起 rewrite proxy"
    setsid nohup node "$PROXY_JS" >> "$LOG_DIR/proxy-ci.log" 2>&1 < /dev/null &
    for _ in $(seq 1 15); do
      sleep 1
      [[ "$(http_code "$PROXY_PORT")" != "000" ]] && break
    done
  else
    log "! 缺少 $PROXY_JS，跳过代理（preview 会 403）"
  fi
else
  log "代理已在运行 code=$proxy_code"
fi

# ═══ 3. 保活守护 ═══
if [[ -x "$KA_DIR/ka-start.sh" ]]; then
  log "拉起保活守护 ${HOURS}h"
  timeout 120 bash "$KA_DIR/ka-start.sh" --hours "$HOURS" --interval 45 2>&1 | sed 's/^/    /'
  sleep 3   # 给守护进程真正落地的窗口（极短时长时它可能已退出，不算失败）
  if pid=$(pgrep -f "keepalive/k[a]\.sh" | head -1) && [[ -n "$pid" ]]; then
    log "✓ 守护运行中 pid=$pid"
  else
    # hours < 0.02 时守护可能已到点自然退出，这是正常的
    if awk -v h="$HOURS" 'BEGIN{exit !(h < 0.02)}'; then
      log "守护已到点退出（时长 ${HOURS}h 过短，属正常）"
    else
      log "✗ 守护未启动"
      exit 1
    fi
  fi
else
  log "✗ 缺少 $KA_DIR/ka-start.sh"
  exit 1
fi

# ═══ 4. 最终确认 ═══
d=$(http_code "$DSH_PORT"); p=$(http_code "$PROXY_PORT")
log "=== remote-up 完成 dsh=$d proxy=$p ==="
echo "RESULT dsh=$d proxy=$p ka=pid$(pgrep -f 'keepalive/k[a]\.sh' | head -1)"
exit 0
