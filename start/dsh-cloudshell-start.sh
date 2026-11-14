#!/usr/bin/env bash
#
# dsh-cloudshell-start.sh — Cloud Shell 一键启动 DSH + 反向代理 (持久化版)
#
# 功能:
#   0. 启动前自愈: 清理 ~/.dsh/*.lock 中"0 字节且 30s 未改动"的孤儿锁。
#      dsh-atomic-write 的锁是 O_EXCL 建的, 崩溃残留(典型诱因: /home 写满)
#      会让之后每次 DSH 启动都必然失败(报 plugin tree failed to load), 而 DSH
#      自身按设计永不清理, 只能运维删除。这是本脚本唯一会删除文件的地方。
#   1. 若 127.0.0.1:3080 未监听, 则后台启动 DSH:
#        - ~/.cache/dsh/path 已记录路径时, 直接执行缓存路径 (不再 npx)
#        - 否则若 ~/.npm/_npx 已有完整安装, 直接复用 (避免重新下载)
#        - 都没有才首次 npx -y @deepseek-ai/dsh web
#      启动成功后把实际 dsh 路径写入 ~/.cache/dsh/path
#   2. 仅当 127.0.0.1:3080 就绪后, 若 127.0.0.1:3081 未监听, 才启动反向代理:
#        - 优先 ~/.local/bin/rewrite-proxy.mjs, 其次 ~/dsh-tools/rewrite-proxy.mjs
#        - 绝不再用 /tmp/rewrite-proxy.mjs
#        - 若 3080 未就绪(600s 超时, 或启动后随即崩溃): 不启动代理,
#          输出 "DSH startup failed" 并退出
#      就绪判据不是"端口通", 而是 dsh_settled(): 端口在 + 静置 3s 后仍在 + HTTP 有响应。
#      DSH 插件激活失败时会"先监听再崩"(约 2s), 只看端口会把将死进程判成就绪,
#      于是代理照常启动 -> 浏览器永久 502。
#   3. 已监听的端口跳过, 避免重复启动
#      例外: 3080 有端口但 HTTP 无响应时, 不自动重启(会与将退出的进程抢端口),
#      而是告警并退出, 由用户确认后重跑。
#
# 持久化 (不依赖 /tmp, 不修改 ~/.bashrc):
#   ~/.local/bin/            反向代理脚本
#   ~/.cache/dsh/            dsh 缓存路径 + 日志
#   npm 缓存用默认 ~/.npm (持久), 不用 /tmp
#
# 不允许: 修改 ~/.bashrc / 修改 ~/blog / 安装额外软件 / 恢复源码仓库
#         (删除文件仅限第 0 节: 0 字节且 30s 未改动的 ~/.dsh/*.lock)
#
# 日志: ~/.cache/dsh/dsh.log (DSH), ~/.cache/dsh/proxy.log (代理)
# 首次 npx 需下载依赖并现场编译 node-pty (Linux 无预编译二进制), 较慢;
#   之后走缓存路径, 秒级启动。
#

# ── node 解析（关键修复）──
# 通过 `gcloud cloud-shell ssh --command` 调用本脚本时是非交互式 shell，
# 不会加载 ~/.bashrc，因此 PATH 里没有 node：
#     PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:...
#     nohup: failed to run command 'node': No such file or directory
# 这是「工作流启动不了 DSH」的真正原因。故这里显式定位 node 并前置到 PATH。
resolve_node() {
  # 1) 已在 PATH
  if command -v node >/dev/null 2>&1; then printf '%s' "$(command -v node)"; return 0; fi
  # 2) nvm 的版本目录（取最高版本）
  local c
  for c in $(ls -d /usr/local/nvm/versions/node/*/bin/node 2>/dev/null | sort -rV); do
    [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  # 3) 常见位置
  for c in /usr/local/bin/node /usr/bin/node "$HOME_DIR/.local/bin/node"; do
    [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}
NODE_BIN="$(resolve_node || true)"
if [ -n "$NODE_BIN" ]; then
  # 把 node 所在目录前置到 PATH，让脚本内所有 `node`/`npx` 调用都能找到
  PATH="$(dirname "$NODE_BIN"):$PATH"
  export PATH
  echo "[env] node=$NODE_BIN"
else
  echo "[env] 警告: 找不到 node，DSH 无法启动" >&2
fi

HOME_DIR="$HOME"
LOCAL_BIN="$HOME_DIR/.local/bin"
CACHE_DIR="$HOME_DIR/.cache/dsh"
DSH_LOG="$CACHE_DIR/dsh.log"
PROXY_LOG="$CACHE_DIR/proxy.log"
DSH_PATH_FILE="$CACHE_DIR/path"
AR_EGRESS_LOG="$CACHE_DIR/ar-egress.log"
AR_RELAY_TARGET="https://ar-relay.13318678430.workers.dev"
# 命名隧道的固定域名 (Cloudflare 面板的 Public Hostname); 仅用于打印认证 URL, 不改隧道配置
TUNNEL_HOSTNAME="dsh.lwsnb.eu.cc"
# 固定 DSH 版本 (npx 首次安装时生效)
# 2026-09-27: 0.1.0-rc.6 -> 0.1.2-rc.1，因 dsh-codearts-auth 需 dsh-llm 导出
#   ToolCallId（0.1.2-rc.1 起才有）；rc.6 下插件加载失败会导致 DSH 整个起不来。
DSH_VERSION="0.2.1-rc.2"

# --- 持久目录 ---
mkdir -p "$LOCAL_BIN" "$CACHE_DIR"

# --- 端口监听检测: 纯 bash, 无外部依赖 ---
is_listening() {
  local port=$1
  (exec 3<>/dev/tcp/127.0.0.1/"$port") 2>/dev/null
}

# --- cloudflared 存活检测（不能用 pgrep -f）---
# 为什么: `pgrep -f "cloudflared tunnel ..."` 会匹配到执行该命令的 shell 自身
#   （shell 的 cmdline 里含有这段字符串），结果永远为真。
#   后果: cloudflared 挂掉后脚本仍判定"已在运行"，永不重启 → 访问隧道 1033 且无法自愈。
# 做法: 遍历 /proc/<pid>/comm，精确比对进程名（comm 只有可执行文件名，不含参数）。
cloudflared_running() {
  local d
  for d in /proc/[0-9]*; do
    [ -r "$d/comm" ] || continue
    [ "$(cat "$d/comm" 2>/dev/null)" = "cloudflared" ] && return 0
  done
  return 1
}

# --- HTTP 层回验: 端口通 != 服务活 ---
# DSH 插件激活失败时会"先监听端口、约 2s 后才退出"(锁等待上限 2s),
# 单次端口探测会把这种将死进程误判成已就绪, 于是照常启动代理 -> 浏览器永久 502。
# 任何 HTTP 响应码(401/303/404...)都算活; 无 curl 时退化为纯端口探测。
dsh_http_alive() {
  command -v curl >/dev/null 2>&1 || return 0
  curl -s -o /dev/null --max-time 3 http://127.0.0.1:3080/ 2>/dev/null
}

# 真就绪 = 端口在 + 静置 3s(> 2s 锁等待, 越过崩溃窗口)后端口仍在 + HTTP 有响应
dsh_settled() {
  is_listening 3080 || return 1
  sleep 3
  is_listening 3080 || return 1
  dsh_http_alive
}

# 查找实际 dsh 可执行文件 (npx 安装的 lib/bin.js)
# 优先固定版本 DSH_VERSION; 找不到再退回任意版本 (最新 mtime)
find_dsh_bin() {
  local f
  for f in $(ls -1t "$HOME_DIR"/.npm/_npx/*/node_modules/@deepseek-ai/dsh/lib/bin.js 2>/dev/null); do
    local pkg_dir
    pkg_dir="$(dirname "$(dirname "$f")")"
    if grep -q "\"version\": \"$DSH_VERSION\"" "$pkg_dir/package.json" 2>/dev/null; then
      echo "$f"
      return
    fi
  done
  ls -1t "$HOME_DIR"/.npm/_npx/*/node_modules/@deepseek-ai/dsh/lib/bin.js 2>/dev/null | head -1
}

# --- 0. 孤儿锁自愈: 崩溃残留的 ~/.dsh/*.lock 会让 DSH 启动即崩 ---
# dsh-atomic-write 用 O_EXCL 建锁, 且源码明言"持有者永不删除既有锁, 孤儿回收是运维动作",
# 即 DSH 自己永远不清理。0 字节 = 建锁进程在写入 pid 前就死了(典型诱因: /home 写满);
# 该文件在持久盘上跨会话存活, 会让之后每次启动都必然失败(表现为浏览器 502)。
# 判据: 0 字节 + 修改时间早于 LOCK_ORPHAN_AGE 秒。
# 为什么不用 fuser / "有无进程持有": 该锁是"存在即持有"型 —— 释放靠 rm,
#   持有者并不保持 fd 打开, 故 fuser 对**活锁**同样报"无持有者", 判据无效。
# 为什么按时间: 一次正常的 writeFile(建锁 + 写 pid)是毫秒级的,
#   "0 字节且 N 秒未改动"必然是建锁进程中途死掉(典型诱因 /home 写满)。
# 只针对 0 字节的锁; 有内容(已写入 pid)的一律不碰。
# 必须开 dotglob: 实际出现的锁名是 .credentials.yaml.lock 和 settings.yaml.lock,
#   而 bash 的 * 默认不匹配点开头的文件名 —— 不开的话 .credentials.yaml.lock 永远清不到
#   (2026-10-07 实测踩过这个洞: 当天日志里 3 次崩溃循环全被它挡住)。用完立即关掉。
LOCK_ORPHAN_AGE=30
shopt -s dotglob
for _lock in "$HOME_DIR"/.dsh/*.lock; do
  [ -f "$_lock" ] || continue
  [ -s "$_lock" ] && continue                    # 有内容 = 已写入 pid, 不动
  _lock_age=$(( $(date +%s) - $(stat -c %Y "$_lock" 2>/dev/null || echo 0) ))
  [ "$_lock_age" -lt "$LOCK_ORPHAN_AGE" ] && continue   # 太新, 可能是正在创建中的活锁
  rm -f "$_lock" && echo "[lock] 已清理孤儿锁 (0 字节, ${_lock_age}s 未改动): $_lock"
done
shopt -u dotglob

# --- 1. DSH: 检查 3080, 未运行则启动 ---
# 记录启动前的日志长度: 之后只从新增部分抓本次 launch token,
# 避免抓到历史崩溃进程残留的失效 token (见第 5 节的认证 URL)
DSH_LOG_OFFSET=$([ -f "$DSH_LOG" ] && wc -c < "$DSH_LOG" || echo 0)
DSH_STARTED_THIS_RUN=0

DSH_READY=0
if is_listening 3080; then
  if dsh_settled; then
    echo "[dsh] 127.0.0.1:3080 已在运行, 跳过启动"
    DSH_READY=1
  else
    # 端口在但 HTTP 不通 = 将死/残留进程。此处不自动重启(会与尚未退出的进程抢端口),
    # 交给用户确认; 关键是绝不启动代理 —— 否则就是浏览器永久 502。
    echo "[dsh] 警告: 3080 有端口但 HTTP 无响应, 疑似崩溃中的残留进程"
    echo "[dsh] 请确认无 dsh 进程后重跑本脚本; 日志: $DSH_LOG"
  fi
else
  echo "[dsh] 启动 DSH..."
  DSH_STARTED_THIS_RUN=1
  DSH_BIN=""

  # (a) 缓存路径 (第二次及以后, 不再 npx)
  if [ -s "$DSH_PATH_FILE" ]; then
    _cand="$(cat "$DSH_PATH_FILE")"
    [ -n "$_cand" ] && [ -f "$_cand" ] && DSH_BIN="$_cand"
  fi

  # (b) 已有的 npx 安装 (首次且 ~/.npm/_npx 已有完整安装, 直接复用)
  if [ -z "$DSH_BIN" ]; then
    _cand="$(find_dsh_bin)"
    [ -n "$_cand" ] && [ -f "$_cand" ] && DSH_BIN="$_cand"
  fi

  if [ -n "$DSH_BIN" ]; then
    echo "[dsh] 使用缓存 dsh: $DSH_BIN"
    # 直接执行缓存路径, 不经过 npx
    nohup node "$DSH_BIN" web --host 127.0.0.1 --port 3080 >> "$DSH_LOG" 2>&1 &
  else
    echo "[dsh] 首次运行: npx -y @deepseek-ai/dsh@$DSH_VERSION web"
    # node-pty 需要 install 脚本现场编译 pty.node (Linux 无预编译二进制);
    #   ~/.npmrc 的 allow-scripts 会拦截它, 故在启动命令里追加 node-pty (不修改 ~/.npmrc)
    # 版本固定为 DSH_VERSION, 与原机器保持一致, 避免新版配置不兼容
    NPMRC_ALLOW=$(grep -E '^[[:space:]]*allow-scripts[[:space:]]*=' "$HOME_DIR/.npmrc" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]')
    ALLOW_SCRIPTS="node-pty${NPMRC_ALLOW:+,$NPMRC_ALLOW}"
    nohup env npm_config_allow_scripts="$ALLOW_SCRIPTS" npx --prefer-offline --no-audit --no-fund -y "@deepseek-ai/dsh@$DSH_VERSION" web --host 127.0.0.1 --port 3080 >> "$DSH_LOG" 2>&1 &
  fi

  # 等待 3080 就绪 (首次 npx 冷安装最长 600s; 缓存路径通常几秒内)
  for _ in $(seq 1 600); do
    is_listening 3080 && break
    sleep 1
  done

  if dsh_settled; then
    echo "[dsh] DSH 已就绪 (127.0.0.1:3080)"
    DSH_READY=1
    # 启动成功后记录实际 dsh 路径, 供下次直接执行
    if [ -z "$DSH_BIN" ]; then
      DSH_BIN="$(find_dsh_bin)"
    fi
    if [ -n "$DSH_BIN" ] && [ -f "$DSH_BIN" ]; then
      printf '%s\n' "$DSH_BIN" > "$DSH_PATH_FILE"
      echo "[dsh] 已记录 dsh 路径: $DSH_BIN"
    fi
  else
    echo "[dsh] 警告: DSH 未就绪 (600s 超时, 或启动后随即崩溃), 请查看 $DSH_LOG"
  fi
fi

# --- 2. 反向代理: 仅当 DSH (3080) 就绪后才启动 ---
if [ "$DSH_READY" != 1 ]; then
  echo "DSH startup failed"
  echo "请查看 $DSH_LOG"
  exit 1
fi

if is_listening 3081; then
  echo "[proxy] 127.0.0.1:3081 已在运行, 跳过启动"
else
  PROXY_SCRIPT=""
  # 优先 ~/.local/bin (持久), 其次 ~/dsh-tools; 不用 /tmp
  for _cand in "$LOCAL_BIN/rewrite-proxy.mjs" "$HOME_DIR/dsh-tools/rewrite-proxy.mjs"; do
    if [ -f "$_cand" ]; then
      PROXY_SCRIPT="$_cand"
      break
    fi
  done

  if [ -z "$PROXY_SCRIPT" ]; then
    echo "[proxy] 警告: 未找到 rewrite-proxy.mjs (~/.local/bin 或 ~/dsh-tools), 跳过"
  else
    # 首选位置缺失而 ~/dsh-tools 有副本时, 复制一份到 ~/.local/bin 持久化
    if [ "$PROXY_SCRIPT" = "$HOME_DIR/dsh-tools/rewrite-proxy.mjs" ] && [ ! -f "$LOCAL_BIN/rewrite-proxy.mjs" ]; then
      cp "$HOME_DIR/dsh-tools/rewrite-proxy.mjs" "$LOCAL_BIN/rewrite-proxy.mjs"
      PROXY_SCRIPT="$LOCAL_BIN/rewrite-proxy.mjs"
      echo "[proxy] 已将代理脚本持久化到 $LOCAL_BIN/rewrite-proxy.mjs"
    fi
    echo "[proxy] 使用代理脚本: $PROXY_SCRIPT"
    nohup node "$PROXY_SCRIPT" > "$PROXY_LOG" 2>&1 &
    # 等待 3081 就绪 (最多 10s)
    for _ in $(seq 1 10); do
      is_listening 3081 && break
      sleep 0.5
    done
    if is_listening 3081; then
      echo "[proxy] 代理已就绪 (127.0.0.1:3081 -> 127.0.0.1:3080)"
    else
      echo "[proxy] 警告: 代理未在 10s 内就绪, 请检查 $PROXY_LOG"
    fi
  fi
fi

# --- 3. AgentRouter egress 代理: CF Worker 反代出口, 端口 8407 ---
if is_listening 8407; then
  echo "[ar-egress] 127.0.0.1:8407 已在运行, 跳过启动"
elif [ ! -f "$HOME_DIR/.local/bin/agentrouter-egress.mjs" ]; then
  echo "[ar-egress] 警告: 未找到 $HOME_DIR/.local/bin/agentrouter-egress.mjs, 跳过"
else
  echo "[ar-egress] 启动 AgentRouter 出站代理 -> $AR_RELAY_TARGET"
  AGENTROUTER_TARGET="$AR_RELAY_TARGET" nohup node "$HOME_DIR/.local/bin/agentrouter-egress.mjs" >> "$AR_EGRESS_LOG" 2>&1 &
  echo $! > "$CACHE_DIR/ar-egress.pid"
  for _ in $(seq 1 10); do
    is_listening 8407 && break
    sleep 0.5
  done
  if is_listening 8407; then
    echo "[ar-egress] AgentRouter 出站代理已就绪 (127.0.0.1:8407 -> $AR_RELAY_TARGET)"
  else
    echo "[ar-egress] 警告: 未在 5s 内就绪, 请查看 $AR_EGRESS_LOG"
  fi
fi

# --- 4. 命名隧道: 把 3081 暴露到固定域名 (token 为空则跳过) ---
TUNNEL_TOKEN_FILE="$HOME_DIR/.cloudflared/tunnel-token"
TUNNEL_LOG="$CACHE_DIR/tunnel-named.log"
if [ ! -s "$TUNNEL_TOKEN_FILE" ] || [ "$(wc -c < "$TUNNEL_TOKEN_FILE" 2>/dev/null || echo 0)" -lt 20 ]; then
  echo "[tunnel] 未配置 $TUNNEL_TOKEN_FILE, 跳过命名隧道 (固定域名不可用)"
elif cloudflared_running; then
  echo "[tunnel] 命名隧道已在运行, 跳过启动"
elif [ ! -x "$LOCAL_BIN/cloudflared" ]; then
  echo "[tunnel] 警告: 未找到 $LOCAL_BIN/cloudflared, 跳过"
else
  echo "[tunnel] 启动命名隧道"
  _tun_off=$([ -f "$TUNNEL_LOG" ] && wc -c < "$TUNNEL_LOG" || echo 0)
  nohup "$LOCAL_BIN/cloudflared" tunnel --no-autoupdate run --token-file "$TUNNEL_TOKEN_FILE" >> "$TUNNEL_LOG" 2>&1 &
  for _ in $(seq 1 20); do
    tail -c "+$((_tun_off + 1))" "$TUNNEL_LOG" 2>/dev/null | grep -q "Registered tunnel connection" && break
    sleep 1
  done
  if tail -c "+$((_tun_off + 1))" "$TUNNEL_LOG" 2>/dev/null | grep -q "Registered tunnel connection"; then
    echo "[tunnel] 命名隧道已就绪"
  else
    echo "[tunnel] 警告: 20s 内未连上, 请查看 $TUNNEL_LOG"
  fi
fi

# --- 4.5 认证 URL: 抓取本次 launch token 并回验 ---
# DSH 打印的 "dsh web: http://.../?token=..." 被 nohup 重定向进了 $DSH_LOG,
# 终端里看不到; 直接点终端里的地址必然 401。这里把它捞出来并回验。
# 代理会把 Host 改写为 127.0.0.1:3080, 故 cookie 与入口无关, token 用一次即可。
DSH_TOKEN=""

# (a) 本次启动新增的日志里找 token。
#     端口就绪与 token 落盘之间有竞态: 端口先通、token 行稍后才 flush,
#     只抓一次会抓空并回退到历史崩溃进程的失效 token(表现为"回验 404"误报),
#     故轮询等待最多 10s。OFFSET=0(日志原为空)时 tail -c +1 即全文, 正好只有本次内容。
if [ "$DSH_STARTED_THIS_RUN" = 1 ] && [ -f "$DSH_LOG" ]; then
  for _ in $(seq 1 20); do
    DSH_TOKEN="$(tail -c "+$((DSH_LOG_OFFSET + 1))" "$DSH_LOG" 2>/dev/null \
      | grep -oE 'dsh web: http://127\.0\.0\.1:[0-9]+/\?token=[A-Za-z0-9_-]+' \
      | tail -1 | sed 's/.*token=//')"
    [ -n "$DSH_TOKEN" ] && break
    sleep 0.5
  done
fi

# (b) 兜底: 仅当本次没启动 DSH(走跳过分支)才取全文件最后一条 ——
#     此时文件末尾的 token 必属于当前在跑的那个进程, 回退是安全的;
#     而本次刚启动时绝不能回退, 否则抓到的是上一轮崩溃进程的死 token。
if [ -z "$DSH_TOKEN" ] && [ "$DSH_STARTED_THIS_RUN" != 1 ] && [ -f "$DSH_LOG" ]; then
  DSH_TOKEN="$(grep -oE 'dsh web: http://127\.0\.0\.1:[0-9]+/\?token=[A-Za-z0-9_-]+' "$DSH_LOG" 2>/dev/null \
    | tail -1 | sed 's/.*token=//')"
fi

# (c) 回验: token 与进程绑定, 只有当前进程返回 303 才算有效
if [ -n "$DSH_TOKEN" ]; then
  _code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    "http://127.0.0.1:3080/?token=$DSH_TOKEN" 2>/dev/null)"
  if [ "$_code" != "303" ]; then
    echo "[auth] 警告: token 回验返回 ${_code:-无响应}, 视为失效"
    DSH_TOKEN=""
  fi
fi

if [ -n "$DSH_TOKEN" ]; then
  echo "[auth] 已取得本次有效 token"
else
  echo "[auth] 警告: 未取得有效 token, 请手动查看 $DSH_LOG 中的 'dsh web:' 行"
fi

# --- 5. 输出 ---
PREVIEW="https://3081-${WEB_HOST:-}"
[ -n "${WEB_HOST:-}" ] || PREVIEW="(未设置 WEB_HOST, 请在终端执行: echo \$WEB_HOST)"
echo
echo "================================"
echo "DSH Cloud Shell Started"
echo "================================"
echo
echo "DSH 地址:"
echo "http://127.0.0.1:3080"
echo
echo "固定地址（命名隧道, 点开即登录）:"
echo "https://$TUNNEL_HOSTNAME/login"
echo
echo "Preview（点开即登录）:"
if [ -n "${WEB_HOST:-}" ]; then
  echo "https://3081-${WEB_HOST}/login"
else
  echo "$PREVIEW"
fi
echo
if [ -n "$DSH_TOKEN" ]; then
  echo "备用直连地址（终端点击会截掉 ?token=..., 需手动整行复制）:"
  echo "https://$TUNNEL_HOSTNAME/?token=$DSH_TOKEN"
  echo
fi
if [ -n "${DSH_BIN:-}" ]; then
  echo "DSH 缓存路径:"
  echo "$DSH_BIN"
  echo
fi
echo "日志:"
echo "$DSH_LOG"
echo "$PROXY_LOG"
echo "$AR_EGRESS_LOG"
echo
echo "查看: tail -f $DSH_LOG"
echo "查看: tail -f $PROXY_LOG"
echo
echo "================================"
