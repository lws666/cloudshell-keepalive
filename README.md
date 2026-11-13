# Cloud Shell CI 保活（GitHub Actions）

对标 [oyz8/ClawCloud-Run](https://github.com/oyz8/ClawCloud-Run) 的 CI 保活思路，换成 Cloud Shell 的实现。

**核心能力**：在 GitHub Actions 页面点一次按钮，远程启动 DSH（+Origin 改写代理），并连续保活 5 小时。

## 和 ClawCloud-Run 的对应关系

| ClawCloud-Run | 本方案 |
|---|---|
| Playwright 打开登录页 | `gcloud` 凭证预置（refresh token） |
| GitHub OAuth + 2FA + 设备验证 | 不需要 —— `users.environments.start` 带 `accessToken` 直接预授权 |
| 登录后访问控制台保活 | `environments.authorize` 换新 token + `cloud-shell ssh` 真跑命令 |
| 提取 Cookie 存回仓库 | 不落盘，token 每次现取 |
| TG 通知验证码 | TG 通知保活结果 |

**优势**：不需要人工批准 2FA、不需要手机守着、不需要浏览器页签常开。

## 为什么这条路能成立

Cloud Shell 有官方 REST API，`start` 支持传 `accessToken`：

```
POST https://cloudshell.googleapis.com/v1/users/me/environments/default:start
{ "accessToken": "<token>" }
```

传了 `accessToken` 后环境「预先完成 gcloud 认证」，不需要走网页登录和 2FA。
这是 CI 能独立完成保活的根本原因。

## 架构

```
GitHub Actions
├── workflow_dispatch（手动按钮）  ← 主力：点一下跑 5 小时
└── schedule  '17 */6 * * *'      ← 兜底：每 6 小时尝试开窗口
        │
        ├─ 1. Sync remote scripts  把脚本推到 Cloud Shell
        ├─ 2. Start DSH on remote  执行 ~/dsh-cloudshell-start.sh
        │                           start_dsh_rc + remote_3080 双重校验
        └─ 3. Keepalive loop       5 小时内每 20 分钟 poke 一次
                ├── authorize     换新 token（不重启 VM，最轻量）
                ├── start         环境没了才起
                └── ssh           每 3 轮真跑命令 + 拉起远端 ka.sh
                        │
                        └── 远端 ka.sh  进程级保活 3080/3081
```

## 一键使用

Actions 页面 → **Run workflow** → 参数保持默认：

| 参数 | 默认 | 说明 |
|---|---|---|
| `hours` | 5 | 保活时长（上限 5.5，GitHub 单 job 硬上限 6h） |
| `interval` | 20 | 每轮间隔分钟（必须 < 40，Cloud Shell 空闲线） |
| `start_dsh` | true | 同时启动 DSH + 代理 |

手动触发即「一键启动 DSH 并保活 5 小时」。

## 部署步骤

### 1. 生成凭证

在 **有浏览器的机器** 上导出 ADC（Cloud Shell 内的 gcloud 凭证是临时的，`credentials.db` 0 行）：

```bash
gcloud auth application-default login \
  --scopes=https://www.googleapis.com/auth/cloud-platform
cat ~/.config/gcloud/application_default_credentials.json
```

或者在 Cloud Shell 里直接用仓库脚本交互获取（30 秒）：

```bash
bash scripts/get-cred.sh        # 打印授权链接，浏览器打开后贴回验证码
```

### ⚠️ 认证的坑

| 凭证类型 | 可用命令 | 说明 |
|---|---|---|
| `authorized_user`（ADC） | `gcloud auth activate-refresh-token` | **不能用** `--cred-file` |
| `service_account` | `gcloud auth activate-service-account --key-file` | SA 调不了 `users/me/*` |
| `external_account` | `gcloud auth login --cred-file` | workload identity pool |

`gcloud auth login --cred-file` 会报：
`Only external account or service account JSON credential file types are supported.`

`users/me/environments` 是**用户级 API**，service account 无法调用，必须用你本人的凭证。
workflow 里按 `type` 字段自动分支处理。

### 2. 启用 Cloud Shell API（必须）

这一步容易漏，漏了会一直 403：

```bash
gcloud services enable cloudshell.googleapis.com --project=<你的项目ID>
```

本仓库实测时该 API 初始状态是 `DISABLED`。

### 3. 配置 Secrets

```bash
gh secret set GCP_CRED_JSON --repo lws666/cloudshell-keepalive \
  < ~/.config/gcloud/application_default_credentials.json
gh secret set GCP_PROJECT --repo lws666/cloudshell-keepalive --body "你的项目ID"

# 可选：Telegram 通知
gh secret set TG_BOT_TOKEN --repo lws666/cloudshell-keepalive --body "123:AAH..."
gh secret set TG_CHAT_ID  --repo lws666/cloudshell-keepalive --body "123456789"
```

### 4. 已部署仓库

```
https://github.com/lws666/cloudshell-keepalive   (private)
```

## 目录结构

```
.
├── .github/workflows/keepalive.yml   # 主 workflow
├── start/
│   └── dsh-cloudshell-start.sh       # 一键启动 DSH+代理+隧道（无 kill，幂等）
├── scripts/
│   ├── keepalive_loop.py             # 5 小时保活循环（含凭证预检）
│   ├── get-cred.sh                   # 交互式获取 refresh token
│   ├── verify-ci.sh                  # 本地预检（19 项）
│   └── remote/                       # 推送到远端的保活脚本
│       ├── ka.sh
│       ├── ka-start.sh
│       ├── ka-stop.sh
│       └── ka-status.sh
└── README.md
```

## 为什么不用「每 25 分钟 cron」

最初按 25 分钟 cron 设计，**实测失败**：

| 日期 | 相邻 schedule 间隔 |
|---|---|
| 11-10 18:52 → 23:51 | 5.0 h |
| 11-10 23:51 → 11-11 04:14 | 4.4 h |
| 11-11 04:14 → 11:57 | **7.7 h** |
| 11-11 11:57 → 19:22 | 7.4 h |
| 11-11 19:22 → 11-12 01:35 | 6.2 h |
| 11-12 01:35 → 08:51 | 7.3 h |

GitHub 免费额度的 `schedule` 是 best-effort，低活跃仓库会被大幅延迟。
**25 分钟配置实际跑成 4–8 小时一次，完全压不住 40 分钟空闲线。**

### 改用的方案：单 job 内循环

```
cron 每 6 小时  →  启动一个 job
                      ↓
                   job 内循环 5 小时，每 20 分钟 poke 一次
```

- GitHub 单 job 上限 **6 小时** → 取 5 小时（`timeout-minutes: 355`）
- cron 精度要求降到**小时级**，免费额度完全够用
- 配额：5h × 每天 4 次 ≈ 20h/周，安全低于 50h 硬限制

## 踩过的坑（全部已修）

### 1. `| tail -N` 吞掉退出码 → 假 success

```bash
gcloud cloud-shell ssh ... | tail -30     # ✗ gcloud 失败也显示 success
```

管道把退出码换成 `tail` 的（恒为 0）。曾经导致 `Start DSH on remote => success`
但 DSH 实际没启动，误导排查很久。

修复：先落文件再取尾部 + 显式检查 `$?` + 执行后二次探测远端 3080。

### 2. `schedule` 列表内插注释 → workflow 不注册

```yaml
on:
  schedule:
    # 这行注释会导致整个 workflow 不被注册
    - cron: '*/25 * * * *'
```

现象：`actions/workflows` 返回 `total_count: 0`，`gh workflow run` 报 404。
修复：注释移到 `on:` 之前。

### 3. 开机钩子被 `exec` 阻塞 → 守护从未恢复

`dsh-start.sh` 结尾是 `exec node`（前台阻塞）。钩子里写 `nohup ... &` 仍会被等待，
导致后面的 `ka-start.sh` 永远轮不到执行。

修复：`setsid nohup ... < /dev/null &`，钩子 3.1 秒返回。

### 4. bash 算术不支持小数

`HOURS=0.05` 时 `$(( HOURS * 3600 ))` 直接报错，导致短时长测试全挂。

修复：改用 `awk -v h="$HOURS" 'BEGIN{printf "%d", h*3600}'`。

### 5. 凭证失效时白占 5 小时额度

修复：主循环前加零成本预检（检查凭证文件 / ACTIVE 账号），无凭证秒级退出。

## 安全

- `dsh-cloudshell-start.sh` **无 `kill`/`pkill`**，对已运行服务走「跳过」分支，CI 反复触发安全。
- 别在会话内 kill 3080 —— 那是承载 DSH 本体的进程。
- `GCP_CRED_JSON` 等价于账号长期访问权，只放私有仓库 Secrets。
- 撤销：`bash scripts/get-cred.sh --revoke`

## 实测记录

| 环节 | 结果 |
|---|---|
| workflow 注册 | ✓ |
| checkout / setup-gcloud | ✓ |
| 凭证写入与激活 | ✓ 自动识别 `authorized_user` 并走 `activate-refresh-token` |
| Cloud Shell API | ✓ 从 `DISABLED` 启用为 `ENABLED` |
| `environments:start` | ✓ 返回 `done: true`，环境 `RUNNING` |
| `environments:authorize` | ✓ `done: true` |
| 一键启动 DSH | ✓ `start_dsh_rc=0` / `remote_3080=401` / `ka_start_rc=0` |
| 保活循环 | ✓ 3 轮全成功，`authorize` + `ssh` 均生效 |
| 本地预检 | ✓ 19 项全通过 |
