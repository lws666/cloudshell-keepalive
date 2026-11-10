#!/usr/bin/env bash
# gen-cred.sh — 在 Cloud Shell 里生成 CI 用的 gcloud 凭证 JSON
#
# 为什么需要这一步:
#   users/me/environments 是「用户级」API，service account 调不了。
#   所以 CI 必须用你本人的凭证。gcloud 凭证的 refresh token 可以长期复用，
#   放进 GitHub Secrets 后 CI 就能以你的身份调用 Cloud Shell API。
#
# 用法:
#   bash gen-cred.sh                 # 生成并打印（会写入 ~/.gcp_cred_ci.json）
#   bash gen-cred.sh --show          # 只显示已生成的凭证
#   bash gen-cred.sh --revoke        # 用完后撤销（可选，安全卫生）
#
# 安全提示:
#   该 JSON 等价于你账号的长期访问权。只贴进目标仓库的 Secrets，
#   不要提交、不要贴到聊天窗口。用完可 revoke。

set -uo pipefail

OUT="$HOME/.gcp_cred_ci.json"
SCOPE="https://www.googleapis.com/auth/cloud-platform"

case "${1:-}" in
  --show)
    [[ -f "$OUT" ]] && cat "$OUT" || echo "还没生成，先跑 bash gen-cred.sh"
    exit 0
    ;;
  --revoke)
    if [[ -f "$OUT" ]]; then
      rt=$(python3 -c "import json;print(json.load(open('$OUT')).get('refresh_token',''))" 2>/dev/null)
      if [[ -n "$rt" ]]; then
        curl -s -X POST https://oauth2.googleapis.com/revoke -d "token=$rt" >/dev/null \
          && echo "refresh token 已撤销" || echo "撤销失败（可能已失效）"
        shred -u "$OUT" 2>/dev/null || rm -f "$OUT"
      fi
    fi
    exit 0
    ;;
esac

echo "=== 1. 检查 gcloud 登录状态 ==="
if ! gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | grep -q .; then
  echo "当前 Cloud Shell 内没有 gcloud 凭证。"
  echo "请先在本机（或任意有浏览器的机器）登录，再用 --cred-file 导出："
  echo
  echo "  gcloud auth login --update-adc"
  echo "  # 导出可复用的凭证文件："
  echo "  gcloud auth application-default login --scopes=$SCOPE"
  echo "  cat ~/.config/gcloud/application_default_credentials.json"
  echo
  echo "把该 JSON 整体作为 GCP_CRED_JSON 存进 GitHub Secrets 即可。"
  exit 1
fi

ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format='value(account)' | head -1)
echo "当前账号: $ACCOUNT"

echo
echo "=== 2. 尝试直接导出 ADC 文件 ==="
ADC="$HOME/.config/gcloud/application_default_credentials.json"
if [[ -f "$ADC" ]]; then
  cp "$ADC" "$OUT" && chmod 600 "$OUT"
  echo "已复制现有 ADC → $OUT"
else
  echo "本机无 ADC，尝试用 refresh token 组装..."
  RT=$(gcloud auth print-refresh-token "$ACCOUNT" 2>/dev/null || true)
  if [[ -z "$RT" ]]; then
    echo "取不到 refresh token（Cloud Shell 里的凭证通常是临时的）。"
    echo "请按上面第 1 步在有浏览器的机器上导出 ADC JSON。"
    exit 1
  fi
  python3 - "$ACCOUNT" "$RT" "$OUT" <<'PY'
import json, sys
acct, rt, out = sys.argv[1], sys.argv[2], sys.argv[3]
blob = {
    "type": "authorized_user",
    "client_id": "32555940559.apps.googleusercontent.com",
    "client_secret": "ZmssLNjJy2998hD4CTg2ejr2",
    "refresh_token": rt,
    "account": acct,
}
open(out, "w").write(json.dumps(blob, indent=2))
print("已写入", out)
PY
  chmod 600 "$OUT" 2>/dev/null
fi

[[ -f "$OUT" ]] || { echo "生成失败"; exit 1; }

echo
echo "=== 3. 验证凭证可用 ==="
python3 - "$OUT" <<'PY'
import json, sys, urllib.request, urllib.parse
b = json.load(open(sys.argv[1]))
data = urllib.parse.urlencode({
    "client_id": b["client_id"],
    "client_secret": b["client_secret"],
    "refresh_token": b["refresh_token"],
    "grant_type": "refresh_token",
}).encode()
try:
    r = urllib.request.urlopen("https://oauth2.googleapis.com/token", data=data, timeout=20)
    tok = json.load(r)
    print("✓ 凭证有效，access_token 长度", len(tok.get("access_token", "")))
    print("  scope:", tok.get("scope", "")[:160])
except Exception as e:
    print("✗ 凭证无效:", e)
    sys.exit(1)
PY

echo
echo "=== 4. 下一步 ==="
cat <<EOF
1) 复制下面内容，存为 GitHub 仓库 Secrets → GCP_CRED_JSON：

$(cat "$OUT")

2) 同名建议同时加：
   GCP_PROJECT     = 你的项目 ID
   TG_BOT_TOKEN    = (可选) Telegram 通知
   TG_CHAT_ID      = (可选)

3) 把 .github/workflows/keepalive.yml 放进仓库，启用 Actions。
EOF
