#!/usr/bin/env bash
# get-cred.sh — 在 Cloud Shell 里直接拿到 CI 用的 refresh token（无需另找机器）
#
# 原理: gcloud auth login 走 OAuth 授权码流程，加 access_type=offline 会返回
#       refresh token。Cloud Shell 里跑会打印一条授权链接，你在浏览器打开、
#       复制验证码贴回来即可。全程 30 秒。
#
# 用法:
#   bash get-cred.sh              交互式获取（推荐）
#   bash get-cred.sh --check      只校验已有的 ~/.gcp_cred_ci.json
#   bash get-cred.sh --show       显示已生成的凭证
#   bash get-cred.sh --revoke     撤销并删除
#
# 产物: ~/.gcp_cred_ci.json（600 权限，含 refresh_token）

set -uo pipefail
OUT="$HOME/.gcp_cred_ci.json"
CFG="$HOME/.config/gcloud-ci"
REPO="${REPO:-你的账号/cloudshell-keepalive}"

case "${1:-}" in
  --show)   [[ -f "$OUT" ]] && cat "$OUT" || echo "还没生成"; exit 0 ;;
  --revoke)
    if [[ -f "$OUT" ]]; then
      rt=$(python3 -c "import json;print(json.load(open('$OUT')).get('refresh_token',''))" 2>/dev/null)
      [[ -n "$rt" ]] && curl -s -X POST https://oauth2.googleapis.com/revoke -d "token=$rt" >/dev/null && echo "token 已撤销"
      shred -u "$OUT" 2>/dev/null || rm -f "$OUT"
      echo "本地已删除"
    fi
    exit 0 ;;
  --check)
    [[ -f "$OUT" ]] || { echo "无凭证文件，先跑 bash get-cred.sh"; exit 1; }
    ;;
esac

# ── 校验 ──
verify() {
  python3 - "$1" <<'PY'
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
    print("  ✓ 有效, access_token 长度",len(t.get("access_token","")))
    sc=t.get("scope","")
    print("  scope 含 cloud-platform:", "cloud-platform" in sc)
except Exception as e:
    print("  ✗ 无效:",e); sys.exit(1)
PY
}

if [[ "${1:-}" == "--check" ]]; then
  echo "=== 校验 $OUT ==="; verify "$OUT"; exit $?
fi

echo "════════════════════════════════════════════"
echo "  在 Cloud Shell 内直接获取 CI 凭证"
echo "════════════════════════════════════════════"
echo
echo "接下来会打印一条 Google 授权链接。你在当前浏览器打开它、"
echo "选账号、同意授权，然后把页面显示的验证码贴回来。"
echo

mkdir -p "$CFG"
export CLOUDSDK_CONFIG="$CFG"

# 用独立配置目录，避免污染 Cloud Shell 自己的临时凭证
echo "--- 开始授权（下面会出现链接）---"
echo
gcloud auth login --no-launch-browser --brief --update-adc 2>&1 | tee /tmp/gc-login.log

RC=$?
echo
if (( RC != 0 )); then
  echo "授权未完成（rc=$RC）。重跑本脚本再试一次。"
  exit 1
fi

# ── 导出 ADC ──
ADC="$CFG/application_default_credentials.json"
if [[ ! -f "$ADC" ]]; then
  echo "--- 未自动生成 ADC，再跑一次 ADC 授权 ---"
  gcloud auth application-default login --no-launch-browser \
    --scopes=https://www.googleapis.com/auth/cloud-platform 2>&1 | tee -a /tmp/gc-login.log
fi

if [[ -f "$ADC" ]]; then
  cp "$ADC" "$OUT"; chmod 600 "$OUT"
  echo "已生成 $OUT"
elif [[ -f "$CFG/credentials.db" ]]; then
  echo "--- 从 credentials.db 提取 refresh token ---"
  ACCT=$(CLOUDSDK_CONFIG="$CFG" gcloud auth list --format='value(account)' 2>/dev/null | head -1)
  RT=$(CLOUDSDK_CONFIG="$CFG" gcloud auth print-refresh-token "$ACCT" 2>/dev/null || true)
  if [[ -n "$RT" ]]; then
    python3 - "$ACCT" "$RT" "$OUT" <<'PY'
import json,sys
json.dump({"type":"authorized_user",
  "client_id":"32555940559.apps.googleusercontent.com",
  "client_secret":"ZmssLNjJy2998hD4CTg2ejr2",
  "refresh_token":sys.argv[2],"account":sys.argv[1]}, open(sys.argv[3],"w"), indent=2)
PY
    chmod 600 "$OUT"; echo "已生成 $OUT"
  fi
fi

[[ -f "$OUT" ]] || { echo "生成失败，看 /tmp/gc-login.log"; exit 1; }

echo
echo "=== 校验 ==="
verify "$OUT" || exit 1

echo
echo "════════════════════════════════════════════"
echo "  填入 GitHub Secrets（直接复制执行）"
echo "════════════════════════════════════════════"
cat <<EOF

gh secret set GCP_CRED_JSON --repo $REPO < $OUT
gh secret set GCP_PROJECT   --repo $REPO --body "\$(gcloud config get-value project 2>/dev/null)"

gh workflow run keepalive.yml --repo $REPO
gh run watch --repo $REPO

EOF
