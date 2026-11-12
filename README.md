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

**在有浏览器的机器上**（不是 Cloud Shell 里 —— Cloud Shell 的 gcloud 凭证是临时的，`credentials.db` 里 0 行）：

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

### ⚠️ 认证的坑（已踩并修复）

| 凭证类型 | 可用命令 | 说明 |
|---|---|---|
| `authorized_user`（ADC） | `gcloud auth activate-refresh-token` | **不能用** `--cred-file` |
| `service_account` | `gcloud auth activate-service-account --key-file` | SA 调不了 `users/me/*` |
| `external_account` | `gcloud auth login --cred-file` | workload identity pool |

`gcloud auth login --cred-file` 会报：
`Invalid value for [--cred-file]: Only external account or service account JSON credential file types are supported.`

所以脚本按 `type` 字段分支处理，workflow 里也做了同样判断。
`users/me/environments` 是**用户级 API**，service account 无法调用，必须用你本人的凭证。

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

### 4. 已创建好的仓库

本方案已实际部署并验证：

```
https://github.com/lws666/cloudshell-keepalive   (private)
```

只差填入真实 `GCP_CRED_JSON`，配完即自动运行。

### 5. 手动触发一次验证

```bash
gh workflow run keepalive.yml --repo <你的账号>/cloudshell-keepalive
gh run watch --repo <你的账号>/cloudshell-keepalive
```

看到 `start=✓ authorize=✓ ssh=✓` 就通了，之后每 25 分钟自动跑。

## 循环内每轮动作

脚本 `scripts/cloudshell_keepalive.py` 按强度递增执行：

| 动作 | API / 命令 | 频率 | 作用 |
|---|---|---|---|
| `authorize` | `POST :authorize` | 每轮 | 换新 token，**不重启 VM**，最轻量 |
| `start` | `POST :start` | authorize 失败时 | 环境没了就起，带 token 预授权 |
| `ssh` | `gcloud cloud-shell ssh` | 每 3 轮 | 真跑远端命令 + 顺带拉起远端 `ka.sh` |

失败退避：连续 3 轮失败 → 间隔翻倍（上限 30 分钟）→ 并发 Telegram 告警。

## 为什么不用 "每 25 分钟 cron"（关键修正）

最初按 25 分钟 cron 设计，**实测失败**：

| 日期 | 相邻 schedule 间隔 |
|---|---|
| 11-10 18:52 → 23:51 | 5.0 h |
| 11-10 23:51 → 11-11 04:14 | 4.4 h |
| 11-11 04:14 → 11:57 | **7.7 h** |
| 11-11 11:57 → 19:22 | 7.4 h |
| 11-11 19:22 → 11-12 01:35 | 6.2 h |
| 11-12 01:35 → 08:51 | 7.3 h |

GitHub 免费额度的 `schedule` 是 best-effort：低活跃仓库、排队高峰时会被大幅延迟。
**25 分钟配置实际跑成 4–8 小时一次，完全压不住 40 分钟空闲线。**

### 改用的方案：单 job 内循环

```
cron 每 4 小时  →  启动一个 job
                      ↓
                   job 内循环 5 小时，每 20 分钟 poke 一次
                      ↓
                   覆盖整个保活窗口
```

- GitHub 单 job 上限 **6 小时** → 取 5 小时（`timeout-minutes: 355`）
- 循环内 20 分钟一轮，稳稳压在 40 分钟空闲线内
- cron 精度要求降到**小时级**，免费额度完全够用
- 还省额度：原来 24h 要触发 57 次，现在 6 次


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


## 实测记录

| 环节 | 结果 |
|---|---|
| workflow 注册 | ✓（踩过坑：`schedule` 列表内插注释会导致整个 workflow 不被注册） |
| checkout / setup-gcloud | ✓ |
| 凭证写入 | ✓ 缺 secret 时报 `missing secret GCP_CRED_JSON` 并退出 |
| 凭证类型识别 | ✓ 正确识别 `authorized_user` |
| refresh token 激活 | ✓ 走对命令（假 token 被 Google 拒绝属预期） |
| API 调用链 | ✓ mock 验证 `POST :start` 带 accessToken → 轮询 operations |
| 端到端 | 待真实凭证 |

### 另一个坑：workflow 不注册

`on.schedule` 下面插注释会让 GitHub Actions 解析器拒绝整个文件：

```yaml
on:
  schedule:
    # ← 这行注释会导致 workflow 不被注册
    - cron: '*/25 * * * *'
```

现象：`actions/workflows` 返回 `total_count: 0`，`gh workflow run` 报 404。
解决：把注释移到 `on:` 之前。


## 第 3 天复盘：两个致命问题（已修）

### 问题 1：开机钩子卡死，守护从未恢复

**现象**：VM 在 13:30 重启，`customize_environment_done` 有创建时间戳，
但 `boot.log` 停在两天前，守护进程不存在。

**根因**：`dsh-start.sh` 结尾是 `exec node ...`（前台阻塞）。
钩子里写 `nohup bash dsh-start.sh &` 仍会被钩子等待，导致后面的
`ka-start.sh` 永远轮不到执行。钩子被卡住 → Cloud Shell 视为未完成 → 守护永不启动。

**修复**：
```bash
setsid nohup bash dsh-start.sh --no-clean >> log 2>&1 < /dev/null &
```
`setsid` 脱离进程组 + `< /dev/null` 断开 stdin，钩子 3.1 秒即返回。

**验证**：改后实测钩子 3.1s 完成，DSH 就绪、tmux 就绪、守护 pid 正常。

### 问题 2：CI cron 精度不可靠

见上面「为什么不用每 25 分钟 cron」章节。

### 教训

| 假设 | 实际 | 修正 |
|---|---|---|
| GitHub cron 能稳定 25 分钟 | 实际 4–8 小时 | 改单 job 循环 |
| `nohup ... &` 就够后台化 | `exec` 进程仍阻塞父脚本 | 必须 `setsid` |
| 钩子会每天/每次登录都跑 | 只在 VM 开机跑一次 | 不能依赖它做周期任务 |
