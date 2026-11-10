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

echo "═══ 2. cron 表达式 ═══"
cron=$(python3 -c "
import yaml
d=yaml.safe_load(open('.github/workflows/keepalive.yml'))
on=d.get('on') or d.get(True)
print(on['schedule'][0]['cron'])")
echo "  cron=$cron"
[[ "$cron" == "*/25 * * * *" ]] && ok "每 25 分钟（< 40 分钟空闲线）" || bad "cron 间隔过大"

echo "═══ 3. Python 脚本 ═══"
python3 -m py_compile scripts/cloudshell_keepalive.py && ok "语法通过" || bad "语法错误"
grep -q 'ENV_NAME}:start' scripts/cloudshell_keepalive.py && ok "含 :start API" || bad "缺 :start"
grep -q "ENV_NAME}:authorize" scripts/cloudshell_keepalive.py && ok "含 :authorize API" || bad "缺 :authorize"
grep -q "cloud-shell.*ssh" scripts/cloudshell_keepalive.py && ok "含 ssh 动作" || bad "缺 ssh"

echo "═══ 4. Shell 脚本 ═══"
for f in scripts/*.sh; do
  bash -n "$f" && ok "$f 语法通过" || bad "$f 语法错误"
done

echo "═══ 5. 无凭证时的失败行为 ═══"
out=$(env -u GCP_CRED_JSON -u GCS_ACCESS_TOKEN python3 scripts/cloudshell_keepalive.py 2>&1); rc=$?
[[ $rc -eq 1 ]] && ok "无凭证时 rc=1（会红，能告警）" || bad "无凭证时 rc=$rc，行为不对"
echo "$out" | grep -q "无可用凭证" && ok "给出了明确原因" || bad "错误信息不清"

echo "═══ 6. secret 引用与 workflow 一致 ═══"
for s in GCP_CRED_JSON GCP_PROJECT TG_BOT_TOKEN TG_CHAT_ID; do
  grep -q "secrets.$s" .github/workflows/keepalive.yml && ok "workflow 引用 $s" || bad "workflow 缺 $s"
done

echo
echo "──── $PASS 通过 / $FAIL 失败 ────"
