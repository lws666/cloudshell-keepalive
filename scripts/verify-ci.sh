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
assert len(crons) == 1 and '*/4' in crons[0], f"cron 应约每 4 小时一次: {crons}"
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

echo "═══ 3. Python 脚本 ═══"
python3 -m py_compile scripts/keepalive_loop.py && ok "语法通过" || bad "语法错误"
grep -q 'ENV_NAME}:start' scripts/keepalive_loop.py && ok "含 :start API" || bad "缺 :start"
grep -q "ENV_NAME}:authorize" scripts/keepalive_loop.py && ok "含 :authorize API" || bad "缺 :authorize"
grep -q "cloud-shell.*ssh" scripts/keepalive_loop.py && ok "含 ssh 动作" || bad "缺 ssh"

echo "═══ 4. Shell 脚本 ═══"
for f in scripts/*.sh; do
  bash -n "$f" && ok "$f 语法通过" || bad "$f 语法错误"
done

echo "═══ 5. 无凭证快速失败（不白占 CI 额度）═══"
t0=$(date +%s)
out=$(timeout 60 env -u GCP_CRED_JSON python3 scripts/keepalive_loop.py 2>&1); rc=$?
t1=$(date +%s); dur=$((t1-t0))
[[ $rc -eq 1 ]] && ok "无凭证时 rc=1" || bad "无凭证时 rc=$rc，行为不对"
(( dur < 60 )) && ok "1 秒级退出（实际 ${dur}s），不会白占 5h 额度" || bad "耗时 ${dur}s，会白占额度"
echo "$out" | grep -q "预检失败" && ok "给出明确原因" || bad "错误信息不清"

echo "═══ 6. secret 引用与 workflow 一致 ═══"
for s in GCP_CRED_JSON GCP_PROJECT TG_BOT_TOKEN TG_CHAT_ID; do
  grep -q "secrets.$s" .github/workflows/keepalive.yml && ok "workflow 引用 $s" || bad "workflow 缺 $s"
done

echo
echo "──── $PASS 通过 / $FAIL 失败 ────"
