#!/usr/bin/env bash
# gen-cred.sh — 生成 CI 用的 gcloud 凭证（严格版，已按实测坑位修正）
#
# 关键约束（实测确认）:
#   * users/me/environments 是「用户级」API，service account 调不了 → 必须用你本人凭证
#   * Cloud Shell 容器内的 gcloud 凭证是临时的（credentials.db 0 行），不能拿来复用到 CI
#   * gcloud auth login --cred-file 只接受 service_account / external_account，
#     不接受 authorized_user → authorized_user 必须走 activate-refresh-token
#
# 用法:
#   bash gen-cred.sh          生成并校验
#   bash gen-cred.sh --show   显示已生成内容
#   bash gen-cred.sh --revoke 撤销并删除
#
# 该 JSON 等价于你账号的长期访问权：只放进私有仓库 Secrets。

set -uo pipefail
OUT="$HOME/.gcp_cred_ci.json"
SCOPE="https://www.googleapis.com/auth/cloud-platform"

case "${1:-}" in
  --show)
    [[ -f "$OUT" ]] && cat "$OUT" || echo "还没生成，先跑 bash gen-cred.sh"; exit 0 ;;
  --revoke)
    if [[ -f "$OUT" ]]; then
      rt=$(python3 -c "import json;print(json.load(open('$OUT')).get('refresh_token',''))" 2>/dev/null)
      [[ -n "$rt" ]] && curl -s -X POST https://oauth2.googleapis.com/revoke -d "token=$rt" >/dev/null \
        && echo "refresh token 已撤销"
      shred -u "$OUT" 2>/dev/null || rm -f "$OUT"
      echo "本地凭证已删除"
    fi
    exit 0 ;;
esac

echo "=== 1. 检查能否在本机直接生成 ==="
ADC="$HOME/.config/gcloud/application_default_credentials.json"

if [[ -f "$ADC" ]] && python3 -c "
import json,sys
b=json.load(open('$ADC'))
sys.exit(0 if b.get('refresh_token') else 1)" 2>/dev/null; then
  cp "$ADC" "$OUT"; chmod 600 "$OUT"
  echo "已复制现有 ADC → $OUT"
else
  echo "本机没有可用的 ADC 文件。"
  echo
  echo "本机 gcloud 状态:"
  gcloud auth list --format='value(account)' 2>/dev/null | sed 's/^/  /' || echo "  (无)"
  echo
  if gcloud auth list --format='value(account)' 2>/dev/null | grep -q .; then
    ACCOUNT=$(gcloud auth list --format='value(account)' 2>/dev/null | head -1)
    echo "检测到账号 $ACCOUNT，尝试用 refresh token 组装..."
    RT=$(gcloud auth print-refresh-token "$ACCOUNT" 2>/dev/null || true)
    if [[ -n "$RT" ]]; then
      python3 - "$ACCOUNT" "$RT" "$OUT" <<'PY'
import json,sys
acct,rt,out=sys.argv[1],sys.argv[2],sys.argv[3]
json.dump({"type":"authorized_user",
  "client_id":"32555940559.apps.googleusercontent.com",
  "client_secret":"ZmssLNjJy2998hD4CTg2ejr2",
  "refresh_token":rt,"account":acct}, open(out,"w"), indent=2)
print("已写入",out)
PY
      chmod 600 "$OUT"
    fi
  fi
fi

if [[ ! -f "$OUT" ]]; then
  cat <<EOF

────────────────────────────────────────────
需要在【有浏览器的机器】上导出凭证（不是 Cloud Shell）：

  gcloud auth application-default login \\
    --scopes=$SCOPE

  cat ~/.config/gcloud/application_default_credentials.json

把输出的整段 JSON 作为 GitHub Secret GCP_CRED_JSON 填入。
────────────────────────────────────────────
EOF
  exit 1
fi

echo
echo "=== 2. 校验凭证有效性 ==="
python3 - "$OUT" <<'PY'
import json,sys,urllib.request,urllib.parse
b=json.load(open(sys.argv[1]))
print("  type:", b.get("type"))
if not b.get("refresh_token"):
    print("  ✗ 缺 refresh_token"); sys.exit(1)
data=urllib.parse.urlencode({
    "client_id":b.get("client_id",""),
    "client_secret":b.get("client_secret",""),
    "refresh_token":b["refresh_token"],
    "grant_type":"refresh_token"}).encode()
try:
    r=urllib.request.urlopen("https://oauth2.googleapis.com/token",data=data,timeout=20)
    t=json.load(r)
    print("  ✓ 有效，access_token 长度", len(t.get("access_token","")))
    print("  scope:", (t.get("scope") or "")[:120])
except Exception as e:
    print("  ✗ 无效:", e); sys.exit(1)
PY
rc=$?
[[ $rc -ne 0 ]] && exit 1

echo
echo "=== 3. 填入 GitHub Secrets（复制即用）==="
cat <<EOF
gh secret set GCP_CRED_JSON --repo lws666/cloudshell-keepalive < $OUT
gh secret set GCP_PROJECT   --repo lws666/cloudshell-keepalive --body "你的项目ID"

# 可选：Telegram 通知
gh secret set TG_BOT_TOKEN --repo lws666/cloudshell-keepalive --body "123:AAH..."
gh secret set TG_CHAT_ID   --repo lws666/cloudshell-keepalive --body "123456789"

# 填完手动跑一次
gh workflow run keepalive.yml --repo lws666/cloudshell-keepalive
gh run watch --repo lws666/cloudshell-keepalive
EOF
