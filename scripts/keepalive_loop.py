#!/usr/bin/env python3
"""
keepalive_loop.py — 单次 CI job 内持续保活（核心修正）

┌─ 为什么这样设计 ────────────────────────────────────────────┐
│ 实测：GitHub 免费额度的 schedule cron 实际间隔 4.4-7.7 小时，│
│ 完全压不住 Cloud Shell 的 40 分钟空闲线。                    │
│                                                              │
│ 对策：不依赖 cron 精度，改为「一次触发，循环 5 小时」。       │
│   - GitHub 单 job 上限 6 小时 → 5 小时窗口安全               │
│   - 循环内每 20 分钟 poke 一次 → 稳稳压在 40 分钟线内        │
│   - cron 只负责每 4 小时尝试开窗口，失败无所谓               │
└──────────────────────────────────────────────────────────────┘

每轮动作（按成本递增，前一个成功就不做后面的）:
    1. environments.start   —— 环境没起就起（幂等）
    2. environments.authorize —— 换新 accessToken，不重启 VM
    3. cloud-shell ssh      —— 每 3 轮做一次，产生真实活动

token 失效时自动重新取（refresh token 可长期复用）。

环境变量:
    HOURS          运行时长（小时，默认 5，上限 5.5）
    INTERVAL_MIN   每轮间隔分钟（默认 20）
    GCP_PROJECT    项目 ID
    TG_BOT_TOKEN / TG_CHAT_ID  可选通知
    GCP_CRED_JSON  凭证（由 workflow 写入 ~/.gcp_cred.json 并激活）
"""

import json
import os
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

CLOUDSHELL_API = "https://cloudshell.googleapis.com/v1"
ENV_NAME = "users/me/environments/default"

HOURS = float(os.environ.get("HOURS", "5"))
INTERVAL_MIN = float(os.environ.get("INTERVAL_MIN", "20"))
HARD_CAP_H = 5.5          # 留 30 分钟给 checkout/setup，低于 GitHub 6h 上限
SSH_EVERY = 3             # 每 3 轮做一次 ssh

_stop = False


def log(msg):
    ts = datetime.now(timezone.utc).strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


def notify(text):
    token = os.environ.get("TG_BOT_TOKEN", "").strip()
    chat = os.environ.get("TG_CHAT_ID", "").strip()
    if not token or not chat:
        return
    try:
        payload = json.dumps({"chat_id": chat, "text": text, "parse_mode": "HTML"}).encode()
        req = urllib.request.Request(
            f"https://api.telegram.org/bot{token}/sendMessage",
            data=payload, headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=15).read()
    except Exception as e:
        log(f"notify failed: {e}")


def sh(cmd, timeout=400):
    try:
        p = subprocess.run(cmd, timeout=timeout, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, text=True)
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"
    return p.returncode, (p.stdout or "").strip(), (p.stderr or "").strip()


def get_token():
    """取 access token；失败时尝试刷新一次凭证。"""
    rc, out, _ = sh(["gcloud", "auth", "print-access-token"], timeout=60)
    if rc == 0 and out:
        return out.splitlines()[-1].strip()
    log("print-access-token 失败，尝试重新激活凭证")
    cred = os.path.expanduser("~/.gcp_cred.json")
    if os.path.exists(cred):
        blob = json.load(open(cred))
        rt = blob.get("refresh_token", "")
        acct = blob.get("account") or blob.get("client_email") or "ci@local"
        if rt:
            sh(["gcloud", "auth", "activate-refresh-token", acct, rt], timeout=60)
            rc, out, _ = sh(["gcloud", "auth", "print-access-token"], timeout=60)
            if rc == 0 and out:
                return out.splitlines()[-1].strip()
    return ""


def api(method, url, token, body=None, timeout=60):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"raw": raw[:300]}
    except Exception as e:
        return 0, {"error": str(e)}


def wait_op(token, op_name, timeout=240):
    url = f"https://cloudshell.googleapis.com/v1/{op_name}"
    end = time.time() + timeout
    while time.time() < end and not _stop:
        code, body = api("GET", url, token)
        if code != 200:
            return None
        if body.get("done"):
            return body.get("response", {}) if "error" not in body else None
        time.sleep(5)
    return None


def do_start(token):
    code, body = api("POST", f"{CLOUDSHELL_API}/{ENV_NAME}:start", token,
                     {"accessToken": token})
    if code not in (200, 201):
        log(f"  start HTTP {code}: {str(body)[:200]}")
        return False
    op = body.get("name")
    if not op:
        return True
    res = wait_op(token, op)
    if res is None:
        log("  start: operation 未完成")
        return False
    log("  start: 环境就绪")
    return True


def do_authorize(token):
    code, body = api("POST", f"{CLOUDSHELL_API}/{ENV_NAME}:authorize", token,
                     {"accessToken": token})
    if code not in (200, 201):
        log(f"  authorize HTTP {code}: {str(body)[:200]}")
        return False
    op = body.get("name")
    if op:
        wait_op(token, op, timeout=120)
    log("  authorize: token 已刷新")
    return True


def do_ssh():
    remote = (
        'echo ALIVE $(date -u +%FT%TZ); '
        'bash $HOME/keepalive/ka-start.sh --hours 5 --interval 45 >/dev/null 2>&1 || true; '
        'echo REMOTE_OK'
    )
    cmd = ["gcloud", "cloud-shell", "ssh", "--quiet", f"--command={remote}"]
    proj = os.environ.get("GCP_PROJECT", "").strip()
    if proj:
        cmd.append(f"--project={proj}")
    rc, out, err = sh(cmd, timeout=420)
    if rc == 0 and "REMOTE_OK" in out:
        log("  ssh: 远端通道正常，已顺带拉起远端 ka.sh")
        return True
    log(f"  ssh 失败 rc={rc} {err[:150]}")
    return False


def handle_signal(signum, _frame):
    global _stop
    log(f"收到信号 {signum}，准备退出")
    _stop = True


def main():
    global HOURS
    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    if HOURS > HARD_CAP_H:
        log(f"HOURS={HOURS} 超过上限，压到 {HARD_CAP_H}")
        HOURS = HARD_CAP_H

    total = int(HOURS * 3600)
    interval = max(60, int(INTERVAL_MIN * 60))
    rounds = max(1, total // interval)

    log("=" * 52)
    log(f"保活循环启动: {HOURS}h, 每 {INTERVAL_MIN}min 一轮, 共约 {rounds} 轮")
    log(f"预计结束: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S')} UTC + {HOURS}h")
    log("=" * 52)

    start_ts = time.time()
    ok_count = 0
    fail_streak = 0
    n = 0

    while not _stop and (time.time() - start_ts) < total:
        n += 1
        elapsed_min = (time.time() - start_ts) / 60
        remain_min = (total - (time.time() - start_ts)) / 60
        log(f"── 第 {n} 轮  (已跑 {elapsed_min:.0f}min, 剩 {remain_min:.0f}min) ──")

        token = get_token()
        if not token:
            log("  取不到 token，本轮跳过，60s 后重试")
            fail_streak += 1
        else:
            done = False
            if do_authorize(token):
                done = True
            else:
                done = do_start(token)
                if done:
                    token = get_token() or token
                    do_authorize(token)

            if done and n % SSH_EVERY == 1:
                do_ssh()

            if done:
                ok_count += 1
                fail_streak = 0
            else:
                fail_streak += 1

        if fail_streak == 3:
            notify("⚠️ <b>Cloud Shell 保活连续 3 轮失败</b>\n请检查凭证或配额")
            log("连续 3 轮失败，已发通知")

        # 退避：连续失败时拉长间隔，避免无效轰炸
        wait = interval
        if fail_streak >= 3:
            wait = min(interval * 2, 1800)
            log(f"  连续失败 {fail_streak} 轮，本轮等待 {wait//60}min")

        log(f"  本轮完成，等待 {wait//60}min")
        slept = 0
        while slept < wait and not _stop and (time.time() - start_ts) < total:
            time.sleep(min(30, wait - slept))
            slept += 30

    dur_h = (time.time() - start_ts) / 3600
    log("=" * 52)
    log(f"循环结束: 跑了 {n} 轮 / {dur_h:.2f}h，成功 {ok_count} 轮")
    log("=" * 52)
    notify(f"✅ <b>Cloud Shell 保活窗口结束</b>\n跑了 {dur_h:.1f}h，{n} 轮，成功 {ok_count} 轮")
    return 0


if __name__ == "__main__":
    sys.exit(main())
