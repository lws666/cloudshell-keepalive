#!/usr/bin/env bash
# verify-ci.sh — 在本地预检 workflow 与脚本，避免推到 GitHub 才发现错
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PASS=0; FAIL=0
ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad(){ printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "═══ 1. workflow YAML ═══"
python3 - <<'PY' && ok "YAML 结构合法" || bad "YAML 非法"
import yaml,sys
d=yaml.safe_load(open('.github/workflows/keepalive.yml'))
assert 'on' in d or True in d, "缺 on"
j=d['jobs']['keepalive']
assert j['runs-on']=='ubuntu-latest'
assert any('checkout' in str(s.get('uses','')) for s in j['steps'])
print("  steps:", len(j['steps']))
PY

echo "═══ 2. 保活架构 ═══"
python3 - <<'PYEOF' && ok "架构正确（单 job 循环，不依赖 cron 精度）" || bad "架构不对"
import yaml, sys
d = yaml.safe_load(open('.github/workflows/keepalive.yml'))
on = d.get('on') or d.get(True)
crons = [x['cron'] for x in on['schedule']]
print("  crons:", crons)
# 关键: 必须是循环脚本，不能靠 cron 做 25 分钟心跳
steps = str(d['jobs']['keepalive']['steps'])
assert 'keepalive_loop.py' in steps, "没用循环脚本"
timeout = d['jobs']['keepalive']['timeout-minutes']
print(f"  job timeout: {timeout}min")
assert timeout >= 300, "job 时长不足以覆盖 5h"
# cron 只负责开窗口，小时级即可
assert len(crons) == 1 and '*/6' in crons[0], f"cron 应约每 6 小时一次（周配额安全）: {crons}"
PYEOF

echo "═══ 2b. 循环参数 ═══"
python3 - <<'PYEOF' && ok "循环参数合理（20min < 40min 空闲线）" || bad "循环间隔过大"
import re
src = open('scripts/keepalive_loop.py').read()
m = re.search(r'INTERVAL_MIN.*?"(\d+)"', src)
interval = int(m.group(1)) if m else 0
print(f"  默认间隔: {interval}min")
assert interval > 0 and interval <= 30, f"间隔 {interval}min 太大，压不住 40min 空闲线"
PYEOF

echo "═══ 2c. 一键启动脚本 ═══"
if [[ -f start/dsh-cloudshell-start.sh ]]; then
  ok "start/dsh-cloudshell-start.sh 存在"
  grep -q 'dsh-cloudshell-start.sh' .github/workflows/keepalive.yml && ok "workflow 引用它" || bad "workflow 未引用"
  grep -qE '\bkill |pkill ' start/dsh-cloudshell-start.sh && bad "含 kill 操作（危险）" || ok "不含 kill（安全）"
  # 关键：ssh --command 是非交互 shell，PATH 无 node，脚本必须自己定位
  grep -q 'resolve_node' start/dsh-cloudshell-start.sh && ok "含 node 路径自解析（非交互必需）" || bad "缺 node 自解析 → 工作流启动会失败"
  grep -q 'nvm/versions/node' .github/workflows/keepalive.yml && ok "workflow 显式补 PATH（双保险）" || bad "workflow 缺 PATH 兜底"
  grep -qE 'TUNNEL_TOKEN|PASSWORD|SECRET' start/dsh-cloudshell-start.sh && info "含 token 变量名（应为从文件读取）" || true
else
  bad "缺 start/dsh-cloudshell-start.sh"
fi

echo "═══ 2d. SSE 心跳（修复 Cloudflare 1033）═══"
if [[ -f proxy/rewrite-proxy.mjs ]]; then
  ok "proxy/rewrite-proxy.mjs 存在"
  grep -q 'text/event-stream' proxy/rewrite-proxy.mjs && ok "识别 SSE 响应" || bad "缺 SSE 分支"
  ping_ms=$(grep -oE 'PING_MS = [0-9]+' proxy/rewrite-proxy.mjs | grep -oE '[0-9]+' | head -1)
  if [[ -n "$ping_ms" ]] && (( ping_ms <= 15000 )); then
    ok "心跳间隔 ${ping_ms}ms（≤15s，抗 CF 空闲切断）"
  else
    bad "心跳间隔 ${ping_ms:-缺失}ms 过大"
  fi
  grep -q "': ping" proxy/rewrite-proxy.mjs && ok "注入 SSE 注释行" || bad "缺 ping 注入"
  # 302 跳板：CF 只跳转，流量走 Preview，规避长连接切断
  grep -q 'isExternalEntry' proxy/rewrite-proxy.mjs && ok "含 302 跳板逻辑" || bad "缺跳板"
  grep -q 'PREVIEW_HOST' proxy/rewrite-proxy.mjs && ok "读 WEB_HOST 生成 Preview 地址" || bad "缺 Preview 地址生成"
else
  bad "缺 proxy/rewrite-proxy.mjs"
fi

echo "═══ 2e. ka-tmux worker 完整性 ═══"
if [[ -f scripts/remote/ka-tmux.sh ]]; then
  ok "ka-tmux.sh 存在"
  # 关键：所有被 worker 调用的函数都必须 declare -f 序列化进去
  for fn in http_code proc_alive pid_on_port proxy_healthy tunnel_healthy restart_proxy restart_tunnel worker; do
    grep -q "declare -f $fn" scripts/remote/ka-tmux.sh && ok "序列化 $fn" || bad "缺 declare -f $fn（worker 里会缺定义）"
  done
  iv=$(grep -oE 'INTERVAL_MIN:-[0-9]+' scripts/remote/ka-tmux.sh | grep -oE '[0-9]+$' | head -1)
  if [[ -n "$iv" ]] && (( iv <= 10 )); then ok "轮询间隔 ${iv}min（短，故障窗口小）"; else bad "间隔 ${iv:-缺失}min 过大"; fi
  grep -q 'tunnel_healthy' scripts/remote/ka-tmux.sh && ok "含隧道健康检测（不只看进程）" || bad "缺隧道健康检测"
else
  bad "缺 scripts/remote/ka-tmux.sh"
fi

echo "═══ 3. Python 脚本 ═══"
python3 -m py_compile scripts/keepalive_loop.py && ok "语法通过" || bad "语法错误"
grep -q 'ENV_NAME}:start' scripts/keepalive_loop.py && ok "含 :start API" || bad "缺 :start"
grep -q "ENV_NAME}:authorize" scripts/keepalive_loop.py && ok "含 :authorize API" || bad "缺 :authorize"
grep -q "cloud-shell.*ssh" scripts/keepalive_loop.py && ok "含 ssh 动作" || bad "缺 ssh"

echo "═══ 4. Shell 脚本 ═══"
for f in scripts/*.sh; do
  bash -n "$f" && ok "$f 语法通过" || bad "$f 语法错误"
done

echo "═══ 5. 无凭证快速失败（代码路径）═══"
# 不做实际计时：本机 gcloud 会探测 metadata，耗时不稳定；
# CI runner 无 metadata，同一代码路径是秒级失败。
grep -q '无可用凭证' scripts/keepalive_loop.py && ok "有零成本凭证预检分支" || bad "缺预检分支"
grep -q '预检失败' scripts/keepalive_loop.py && ok "预检失败会给明确原因" || bad "错误信息不清"
# 预检必须早于真正的 while 主循环（横幅日志在前不影响）
awk '/预检失败/{p=NR} /while not _stop/{l=NR} END{exit !(p<l && p>0)}' \
  scripts/keepalive_loop.py && ok "预检早于主循环（不会白占 5h 额度）" || bad "预检位置不对"

echo "═══ 6. secret 引用与 workflow 一致 ═══"
for s in GCP_CRED_JSON GCP_PROJECT TG_BOT_TOKEN TG_CHAT_ID; do
  grep -q "secrets.$s" .github/workflows/keepalive.yml && ok "workflow 引用 $s" || bad "workflow 缺 $s"
done

echo
echo "──── $PASS 通过 / $FAIL 失败 ────"
