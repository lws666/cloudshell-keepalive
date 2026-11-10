#!/usr/bin/env python3
"""
cloudshell_keepalive.py — Cloud Shell CI 保活（对应 ClawCloud-Run 的 auto_login.py 角色）

设计对照 ClawCloud-Run:
    ClawCloud                     本脚本
    ─────────────────────────     ──────────────────────────────────
    Playwright 打开登录页      →   gcloud 凭证预置（refresh token）
    GitHub OAuth / 2FA 交互    →   users.environments.start 带 accessToken
    登录后访问控制台保活       →   users.environments.authorize 刷新会话
    提取 Cookie 存回仓库       →   不落盘，token 直接用

三条保活动作（按强度递增，全部走官方 API / CLI）:
    A. environments.start     启动/复用环境，可带 accessToken 预授权
    B. environments.authorize 给运行中的环境换新 accessToken（不动 VM）
    C. cloud-shell ssh --command  真跑一条远端命令，产生真实活动

环境变量:
    GCP_CRED_JSON     gcloud 凭证（--cred-file 格式 JSON 字符串）
    GCP_PROJECT       项目 ID
    GCS_ACCESS_TOKEN  可选的现成 access token（优先用）
    KEEPALIVE_MODE    start | authorize | ssh | all（默认 all）
    TG_BOT_TOKEN      Telegram bot token（可选通知）
    TG_CHAT_ID        Telegram chat id（可选通知）
"""

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

CLOUDSHELL_API = "https://cloudshell.googleapis.com/v1"
ENV_NAME = "users/me/environments/default"


def log(msg):
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    print(f"[{ts}] {msg}", flush=True)


def notify(text):
    """Telegram 通知，失败不影响主流程。"""
    token = os.environ.get("TG_BOT_TOKEN", "").strip()
    chat = os.environ.get("TG_CHAT_ID", "").strip()
    if not token or not chat:
        return
    try:
        data = json.dumps({"chat_id": chat, "text": text, "parse_mode": "HTML"}).encode()
        req = urllib.request.Request(
            f"https://api.telegram.org/bot{token}/sendMessage",
            data=data,
            headers={"Content-Type": "application/json"},
        )
        urllib.request.urlopen(req, timeout=15).read()
        log("Telegram 通知已发送")
    except Exception as e:
        log(f"Telegram 通知失败（不影响主流程）: {e}")


def sh(cmd, timeout=300, check=False, capture=True):
    """跑本地命令，返回 (rc, stdout, stderr)。"""
    log(f"$ {' '.join(cmd) if isinstance(cmd, list) else cmd}")
    try:
        p = subprocess.run(
            cmd, shell=isinstance(cmd, str), timeout=timeout,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
            text=True,
        )
    except subprocess.TimeoutExpired:
        log(f"命令超时 ({timeout}s)")
        return 124, "", "timeout"
    out = (p.stdout or "").strip()
    err = (p.stderr or "").strip()
    if out:
        log(f"  stdout: {out[:800]}")
    if err:
        log(f"  stderr: {err[:800]}")
    if check and p.returncode != 0:
        raise RuntimeError(f"命令失败 rc={p.returncode}: {err[:300]}")
    return p.returncode, out, err


# ─────────────────── 认证 ───────────────────

def setup_auth():
    """把 GCP_CRED_JSON 写盘并用 gcloud 激活。"""
    cred_json = os.environ.get("GCP_CRED_JSON", "").strip()
    if not cred_json:
        log("未提供 GCP_CRED_JSON，尝试使用 CI 环境已有凭证")
        # gcloud auth list 没有 status 字段（--filter=status:ACTIVE 会告警），
        # 直接用 json 判断有没有账号；有 ACTIVE 标记才算数。
        rc, out, _ = sh(["gcloud", "auth", "list", "--format=json"])
        if rc != 0 or not out:
            return False
        try:
            accounts = json.loads(out)
        except Exception:
            return False
        return any(a.get("status") == "ACTIVE" for a in accounts if isinstance(a, dict))

    path = os.path.expanduser("~/.gcp_cred.json")
    with open(path, "w") as f:
        f.write(cred_json)
    os.chmod(path, 0o600)

    # 先在真实 HOME 配置里激活，避免 CI 上 CLOUDSDK_CONFIG 干扰
    os.environ.pop("CLOUDSDK_CONFIG", None)
    rc, _, _ = sh(["gcloud", "auth", "activate-service-account", "--key-file", path])
    if rc == 0:
        log("以 service account 激活成功")
        return True

    # 用户凭证（refresh token 格式）
    rc, _, _ = sh(["gcloud", "auth", "login", "--cred-file", path, "--brief", "--quiet"])
    if rc == 0:
        log("以用户凭证（cred-file）激活成功")
        return True

    # 退化：直接当 refresh token 用
    try:
        blob = json.loads(cred_json)
        rt = blob.get("refresh_token") or blob.get("installed", {}).get("refresh_token")
        acct = blob.get("client_email") or blob.get("account") or "keepalive@ci"
        if rt:
            rc, _, _ = sh(["gcloud", "auth", "activate-refresh-token", acct, rt])
            if rc == 0:
                log("以 refresh token 激活成功")
                return True
    except Exception as e:
        log(f"解析凭证失败: {e}")

    log("认证失败")
    return False


def get_access_token():
    """取得 access token：优先环境变量，其次 gcloud。"""
    tok = os.environ.get("GCS_ACCESS_TOKEN", "").strip()
    if tok:
        log("使用 GCS_ACCESS_TOKEN")
        return tok
    rc, out, _ = sh(["gcloud", "auth", "print-access-token"])
    if rc == 0 and out:
        log("已取得 access token")
        return out.splitlines()[-1].strip()
    log("取 access token 失败")
    return ""


# ─────────────────── API 调用 ───────────────────

def api(method, url, token, body=None, timeout=60):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read().decode() or "{}"
            return r.status, json.loads(raw)
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"raw": raw[:500]}
    except Exception as e:
        return 0, {"error": str(e)}


def wait_operation(token, op_name, timeout=300):
    """轮询 operations.get 直到 done。"""
    url = f"https://cloudshell.googleapis.com/v1/{op_name}"
    deadline = time.time() + timeout
    while time.time() < deadline:
        code, body = api("GET", url, token)
        if code != 200:
            log(f"  operation 查询失败 {code}: {str(body)[:200]}")
            return None
        if body.get("done"):
            if "error" in body:
                log(f"  operation 出错: {body['error']}")
                return None
            return body.get("response", {})
        time.sleep(5)
    log("  operation 超时")
    return None


# ─────────────────── 三种保活动作 ───────────────────

def action_start(token):
    """启动/复用环境，带 accessToken 预授权。"""
    log("── A. environments.start ──")
    url = f"{CLOUDSHELL_API}/{ENV_NAME}:start"
    code, body = api("POST", url, token, {"accessToken": token})
    log(f"  HTTP {code}")
    if code not in (200, 201):
        log(f"  响应: {str(body)[:400]}")
        return False
    op = body.get("name")
    if not op:
        log("  无 operation name，视为已完成")
        return True
    res = wait_operation(token, op)
    if res is None:
        return False
    log(f"  环境就绪: {str(res)[:300]}")
    return True


def action_authorize(token):
    """给运行中的环境换新 accessToken，不重启 VM。"""
    log("── B. environments.authorize ──")
    url = f"{CLOUDSHELL_API}/{ENV_NAME}:authorize"
    code, body = api("POST", url, token, {"accessToken": token})
    log(f"  HTTP {code}")
    if code not in (200, 201):
        log(f"  响应: {str(body)[:400]}")
        return False
    op = body.get("name")
    if op:
        wait_operation(token, op, timeout=180)
    return True


def action_ssh(token):
    """真跑一条远端命令，制造真实活动 + 顺带拉起远端保活。"""
    log("── C. cloud-shell ssh --command ──")
    remote = (
        'echo ALIVE $(date -u +%FT%TZ); '
        'bash $HOME/keepalive/ka-start.sh --hours 5 --interval 45 2>/dev/null || true; '
        'curl -s -o /dev/null -w "dsh=%{http_code} " http://127.0.0.1:3080/ || true; '
        'echo DONE'
    )
    cmd = ["gcloud", "cloud-shell", "ssh", "--quiet", f"--command={remote}"]
    proj = os.environ.get("GCP_PROJECT", "").strip()
    if proj:
        cmd.append(f"--project={proj}")
    rc, out, err = sh(cmd, timeout=420)
    if rc == 0:
        log("  ssh 通道正常")
        return True
    log(f"  ssh 失败 rc={rc}")
    return False


def main():
    mode = os.environ.get("KEEPALIVE_MODE", "all").strip().lower()
    log(f"=== Cloud Shell CI 保活开始 mode={mode} ===")

    if not setup_auth() and not os.environ.get("GCS_ACCESS_TOKEN"):
        log("无可用凭证，终止")
        notify("❌ <b>Cloud Shell 保活失败</b>\n原因: 凭证无效")
        return 1

    token = get_access_token()
    if not token:
        notify("❌ <b>Cloud Shell 保活失败</b>\n原因: 取不到 access token")
        return 1

    results = {}

    # start 是基础动作，其它都建立在环境存在之上
    if mode in ("start", "all"):
        results["start"] = action_start(token)
        # start 之后 token 可能已被环境消费，重新取
        token = get_access_token() or token

    if mode in ("authorize", "all"):
        results["authorize"] = action_authorize(token)
        token = get_access_token() or token

    if mode in ("ssh", "all"):
        results["ssh"] = action_ssh(token)

    ok = all(results.values())
    summary = " ".join(f"{k}={'✓' if v else '✗'}" for k, v in results.items())
    log(f"=== 结果: {summary} ===")

    if ok:
        notify(f"✅ <b>Cloud Shell 保活成功</b>\n{summary}")
    else:
        notify(f"⚠️ <b>Cloud Shell 保活部分失败</b>\n{summary}")

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
