# Cloud Shell CI 保活（GitHub Actions）

对标 [oyz8/ClawCloud-Run](https://github.com/oyz8/ClawCloud-Run) 的 CI 保活思路，换成 Cloud Shell 的实现。

## 和 ClawCloud-Run 的对应关系

| ClawCloud-Run | 本方案 |
|---|---|
| Playwright 打开登录页 | `gcloud` 凭证预置（refresh token） |
| GitHub OAuth + 2FA + 设备验证 | 不需要 —— `users.environments.start` 带 `accessToken` 直接预授权 |
| 登录后访问控制台保活 | `environments.authorize` 换新 token + `cloud-shell ssh` 真跑命令 |
| 提取 Cookie 存回仓库 | 不落盘，token 每次现取 |
| TG 通知验证码 | TG 通知保活结果 |

**核心优势**：不需要人工批准 2FA、不需要手机守着、不需要浏览器页签常开。

## 为什么这条路能成立

Cloud Shell 有官方 REST API，且 `start` 支持传 `accessToken`：

```
POST https://cloudshell.googleapis.com/v1/users/me/environments/default:start
{ "accessToken": "<token>" }
```

传了 `accessToken` 后环境「预先完成 gcloud 认证」，不需要走网页登录和 2FA。
这就是 CI 能独立完成保活的根本原因。

## 快速部署

### 1. 生成凭证

**在有浏览器的机器上**（不是 Cloud Shell 里，Cloud Shell 的凭证是临时的）：

```bash
gcloud auth application-default login \
  --scopes=https://www.googleapis.com/auth/cloud-platform

cat ~/.config/gcloud/application_default_credentials.json
```

得到一个 `authorized_user` 类型的 JSON：

```json
{
  "type": "authorized_user",
  "client_id": "....apps.googleusercontent.com",
  "client_secret": "....",
  "refresh_token": "1//...."
}
```

### 2. 建仓库并推 workflow

```bash
mkdir -p ~/keepalive-ci/.github/workflows
cd ~/keepalive-ci
git init && git add -A && git commit -m "cloudshell keepalive"
gh repo create cloudshell-keepalive --private --source=. --push
```

### 3. 配置 Secrets

```bash
gh secret set GCP_CRED_JSON --repo <你的账号>/cloudshell-keepalive \
  < ~/.config/gcloud/application_default_credentials.json

gh secret set GCP_PROJECT --repo <你的账号>/cloudshell-keepalive --body "你的项目ID"

# 可选：Telegram 通知
gh secret set TG_BOT_TOKEN --repo <你的账号>/cloudshell-keepalive --body "123:AAH..."
gh secret set TG_CHAT_ID  --repo <你的账号>/cloudshell-keepalive --body "123456789"
```

### 4. 手动触发一次验证

```bash
gh workflow run keepalive.yml --repo <你的账号>/cloudshell-keepalive
gh run watch --repo <你的账号>/cloudshell-keepalive
```

看到 `start=✓ authorize=✓ ssh=✓` 就通了，之后每 25 分钟自动跑。

## 三级保活动作

脚本 `scripts/cloudshell_keepalive.py` 按强度递增执行：

| 动作 | API / 命令 | 作用 |
|---|---|---|
| A `start` | `POST :start` | 启动或复用环境，带 token 预授权 |
| B `authorize` | `POST :authorize` | 给运行中的环境换新 token，**不重启 VM** |
| C `ssh` | `gcloud cloud-shell ssh --command` | 真跑远端命令，产生真实活动 + 顺带拉起远端 `ka.sh` |

`KEEPALIVE_MODE` 可只跑其中一个：`start` / `authorize` / `ssh` / `all`（默认）。

## 频率为什么是 25 分钟

| 限制 | 值 | 说明 |
|---|---|---|
| 非交互空闲 | 40 分钟 | 25 分钟 × 安全余量足够 |
| 交互空闲 | 约 1 小时 | 同上 |
| 会话硬上限 | 12 小时 | 本地和 CI 都无法突破 |
| 每周配额 | 50 小时 | Google 侧硬限制 |

GitHub Actions 免费额度的 cron 有 5–15 分钟漂移，25 分钟能稳稳压在 40 分钟线内。
cron 最小粒度是 5 分钟，别想着更密。

## 与本地保活的关系

两层互补，不是二选一：

```
CI（每 25 分钟）  →  防 Cloud Shell 会话被回收
   ↓ 会话活着
远端 ka.sh        →  防 DSH(3080)/代理(3081) 进程死掉
```

CI 的 `ssh` 动作里带了 `ka-start.sh`，所以会话被回收后重建时，
远端服务会自动跟着起来。

## 故障对照

| 现象 | 原因 | 处理 |
|---|---|---|
| `缺少 secret GCP_CRED_JSON` | Secrets 没配 | 按第 3 步配 |
| `凭证无效` | refresh token 过期/被撤销 | 重跑第 1 步换新 |
| `HTTP 403` on `:start` | 项目未启用 Cloud Shell API 或账号权限不足 | 控制台启用 Cloud Shell API |
| `HTTP 429` | 配额超了 | 查 `Session information → Usage quota` |
| `ssh 失败` | SSH key 首次未生成 | 本地先手动跑一次 `gcloud cloud-shell ssh` |
| `operation 超时` | 环境启动慢 | 属正常，下次运行会复用已启动的环境 |

## 安全注意

- `GCP_CRED_JSON` 等价于你账号的长期访问权，只放私有仓库 Secrets。
- 用完可撤销：`curl -X POST https://oauth2.googleapis.com/revoke -d "token=<refresh_token>"`
- 别把它写进代码、日志、issue 或聊天窗口。
