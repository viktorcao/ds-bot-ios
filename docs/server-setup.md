# 服务端部署与认证

本文说明怎么在自己的机器（NAS、家里的 Linux 小主机、云服务器、常开的 Mac 都行）上跑起 DSH + DS Bot，并让手机 App 安全地连上。

已验证的版本：`@deepseek-ai/dsh 0.2.1-rc.2`、`ds-bot 0.2.1`、Node.js 24。DS Bot 还是早期版本，接口可能变化；换版本后如果 App 报错，先看 [docs/protocol.md](protocol.md) 和上游的更新日志。

## 1. 安装 DSH 和 DS Bot 插件

要求：Node.js 22.19+、pnpm 10+（DSH 的插件管理器会调用 pnpm；pnpm 7 会报 `ERR_PNPM_ADDING_TO_ROOT`）。

```bash
mkdir ~/dsh-server && cd ~/dsh-server
npm init -y
npm i @deepseek-ai/dsh@0.2.1-rc.2

# DSH 的数据目录：Bot 团队、聊天记录、设置都在这里。换位置就改这个变量，备份也只需要备份它
export DSH_HOME=$HOME/.dsh

npx dsh plugin --profile web add ds-bot
```

国内网络可以给 npm 设镜像：`npm config set registry https://registry.npmmirror.com`。

### 配模型

DS Bot 用的是 DSH 里配好的模型，**没有模型时 Bot 不会回复**。两种配法：

- 启动后在 DSH 网页端（浏览器打开网关地址）的 设置 → 模型 里配；
- 或者写 `$DSH_HOME/cordis.patch.yml`（DSH 的全局配置补丁），例如接一个 OpenAI 兼容的中转：

```yaml
- id: llm-pi-ai
  config:
    providers:
      relay:
        apiKeyEnv: RELAY_API_KEY          # 密钥放环境变量，不要写进文件
        api: openai-completions           # 或 openai-responses / anthropic-messages
        baseURL: https://your-relay.example/v1
        models:
          - id: my-model
            contextWindow: 131072
            maxTokens: 8192
- id: agent-default-model
  config:
    provider: relay
    model: my-model
```

每个模型都建议写 `contextWindow`，DS Bot 靠它决定什么时候压缩长对话。更多选项见 [DS Bot 文档](https://github.com/Fei2411/DeepSeek-Bot/blob/main/ds-bot/README.md#models)。

## 2. 为什么需要网关

原版 `dsh web` 的登录方式是**一次性令牌**：启动时在日志里打印 `http://127.0.0.1:端口/?token=…`，浏览器带着令牌访问一次，DSH 种下会话 Cookie（`dsh-auth-*`，30 天），之后才能用。它没有账号密码，也不对手机 App 提供拿令牌的办法。

[`server/ds-gateway.mjs`](../server/ds-gateway.mjs) 解决这个问题，单文件、无依赖：

1. 自己启动 `dsh web`（绑定回环地址的随机端口），从输出里读出令牌（日志里只显示 `token=<hidden>`）；
2. 对外监听一个端口（默认 8731），把请求转给 `dsh web`，**包括 WebSocket 和实时事件流（SSE）**；
3. 客户端第一次访问首页、上游回 401 时，网关把它重定向到带令牌的地址，由 DSH 种下 Cookie；
4. 配了账号密码时，**所有请求在到达 DSH 之前先校验 HTTP 基本认证**，不通过直接 401；
5. `dsh web` 崩溃会自动重启（退避 2 秒起，最多 10 次）；重启后令牌变了，App 收到 401 会自动重新登录。

### 网关配置（环境变量）

| 变量 | 默认 | 说明 |
|---|---|---|
| `DS_GATEWAY_PORT` | `8731` | 对外端口 |
| `DS_GATEWAY_HOST` | `0.0.0.0` | 监听地址；只想本机访问（前面有反向代理）就写 `127.0.0.1` |
| `DS_GATEWAY_USER` / `DS_GATEWAY_PASS` | 空 | 基本认证账号密码，**必须同时设置**。不设则只允许内网客户端登录 |
| `DS_GATEWAY_TLS_CERT` / `DS_GATEWAY_TLS_KEY` | 空 | PEM 证书链和私钥路径，设了网关直接提供 HTTPS |
| `DS_GATEWAY_BEHIND_PROXY` | `0` | 前面有 Caddy / nginx 时设为 `1`：按 `X-Forwarded-For` 判断客户端是否内网，按 `X-Forwarded-Proto` 给 Cookie 加 `Secure` |

启动命令写在 `--` 后面，`{PORT}` 会被替换成网关选的回环端口。**shell 里要加引号**：

```bash
export DSH_HOME=$HOME/.dsh
DS_GATEWAY_USER=me DS_GATEWAY_PASS='换成强随机密码' \
  node ds-gateway.mjs -- node_modules/.bin/dsh --profile web --no-open --host 127.0.0.1 --port '{PORT}'
```

## 3. 认证

先想清楚你的使用场景：

| 场景 | 配置 | 风险 |
|---|---|---|
| **A. 只在局域网用** | 不设账号密码，`http://内网IP:8731` | 同一网络里任何人都能打开并控制 Bot。家里可以，公司或公共 Wi-Fi 不行 |
| **B. 局域网 + 密码** | 设 `DS_GATEWAY_USER/PASS`，仍用 `http://内网IP:8731` | 密码在局域网明文传输；比 A 好得多 |
| **C. 公网 + HTTPS + 密码** | 设账号密码，并让 HTTPS 生效（见第 4 节） | 暴露在互联网上，会被扫描和爆破；必须强密码并加限速 |
| **D. VPN（推荐）** | 用 Tailscale / WireGuard，App 里填 VPN 内地址，网关按 A 或 B | 最稳妥；iPhone 要装对应的 VPN 客户端 |

### 增加认证 / 改密码

认证只有一个入口：网关的两个环境变量。

- **新增**：启动时加上 `DS_GATEWAY_USER` 和 `DS_GATEWAY_PASS`，重启网关。
- **改密码**：改环境变量，重启网关。已登录的 App 会提示"用户名或密码不正确"并停在离线状态；到 账号面板 → 退出登录，再用新密码登录即可（`dsh web` 的会话 Cookie 与网关密码无关，聊天数据不受影响）。
- **多个账号**：网关是单账号。需要多账号的话，改 `passesBasicAuth()`（十几行代码，比如读一个账号文件），或者走 VPN 让大家共用内网地址。

### 密码强度与暴力破解

网关**没有登录失败限速**。公网部署时请：

1. 用至少 20 位的随机密码（`openssl rand -base64 24`）；
2. 在反向代理层加限速（nginx `limit_req`，Caddy 的 rate_limit 插件）或用 fail2ban 盯日志；
3. 或者干脆走场景 D。

## 4. HTTPS

App 的 ATS 配置只允许对**局域网**（IP 地址、`.local`、不带域名的主机名）使用明文 HTTP。**公网域名（包括 Tailscale 的 `*.ts.net`）必须是 HTTPS，且证书要被 iOS 信任**（自签证书不行，除非在手机上安装并信任根证书）。

### 方案 1：Caddy 自动证书（最省事）

域名解析到服务器，80/443 端口可达，网关只监听本机：

```bash
DS_GATEWAY_HOST=127.0.0.1 DS_GATEWAY_BEHIND_PROXY=1 DS_GATEWAY_USER=me DS_GATEWAY_PASS='…' \
  node ds-gateway.mjs -- node_modules/.bin/dsh --profile web --no-open --host 127.0.0.1 --port '{PORT}'
```

`Caddyfile`：

```
bot.example.com {
    reverse_proxy 127.0.0.1:8731
}
```

Caddy 会自动处理证书、WebSocket 和事件流。

### 方案 2：nginx

```nginx
server {
    listen 443 ssl;
    server_name bot.example.com;
    ssl_certificate     /etc/letsencrypt/live/bot.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/bot.example.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8731;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $remote_addr;      # 不要用 $proxy_add_x_forwarded_for：那会带上客户端伪造的值
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;             # WebSocket
        proxy_set_header Connection $http_connection;
        proxy_buffering off;                                # 实时事件流（SSE）不能被缓冲
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
```

如果用 Nginx Proxy Manager：关闭"缓存资源（Cache Assets）"；它会把 401/403 也缓存 30 分钟，导致页面空白。

### 方案 3：网关直接提供 HTTPS

```bash
DS_GATEWAY_TLS_CERT=/path/fullchain.pem DS_GATEWAY_TLS_KEY=/path/privkey.pem \
DS_GATEWAY_USER=me DS_GATEWAY_PASS='…' DS_GATEWAY_PORT=8443 \
  node ds-gateway.mjs -- …
```

证书续期后需要重启网关。

## 5. 开机自启（systemd 示例）

用一个**专门的低权限用户**运行（下面假设用户叫 `dsh`，目录 `/opt/dsh-server`）：

```ini
# /etc/systemd/system/ds-gateway.service
[Unit]
Description=DS Bot gateway (dsh web + auth)
After=network-online.target
Wants=network-online.target

[Service]
User=dsh
WorkingDirectory=/opt/dsh-server
Environment=DSH_HOME=/var/lib/dsh
EnvironmentFile=/etc/ds-gateway.env
ExecStart=/usr/bin/node ds-gateway.mjs -- node_modules/.bin/dsh --profile web --no-open --host 127.0.0.1 --port {PORT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

`/etc/ds-gateway.env`（权限 `600`，属主 root）：

```
DS_GATEWAY_USER=me
DS_GATEWAY_PASS=换成强随机密码
RELAY_API_KEY=模型密钥
```

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now ds-gateway
journalctl -u ds-gateway -f
```

> systemd 的 `ExecStart` 里 `{PORT}` 不需要引号。

## 6. 在 App 里连接

登录页填：

- **服务器地址**：`http://192.168.1.10:8731`（局域网，必须写 `http://`）或 `https://bot.example.com`（公网）。不写协议 App 会按 `https://` 处理。
- **用户名 / 密码**：网关的 `DS_GATEWAY_USER/PASS`；没设就留空。

首次连局域网地址时 iOS 会弹"本地网络"权限，要点允许；点了不允许的话，到 设置 → 隐私与安全性 → 本地网络 里打开 DS Bot。

## 7. 排错

| 现象 | 原因与处理 |
|---|---|
| "用户名或密码不正确" | 账号密码和网关的环境变量不一致；或网关前面的反向代理也开了一层自己的认证 |
| "未配置认证时，只允许从局域网访问"（403） | 网关没设账号密码，而请求来自公网（或经反向代理但没设 `DS_GATEWAY_BEHIND_PROXY=1`）。设账号密码，或检查转发头 |
| "服务器返回 502" / "dsh web 不可用" | `dsh web` 在重启或崩溃，看网关日志；一般几秒后恢复 |
| "dsh web 正在启动，稍后重试"（503） | 刚启动，令牌还没出来；若一直这样，日志里应有 `没有看到 ?token=` 的提示，说明启动命令不对 |
| 公网 `http://域名` 连不上 | ATS 禁止明文 HTTP，换 HTTPS |
| "无法验证服务器身份"（证书错误） | 自签或不完整的证书链；用 Let's Encrypt 的 `fullchain.pem` |
| 登录后一直转圈或不停掉线 | 反向代理缓冲了事件流或没转发 WebSocket 升级头；对照第 4 节配置 |
| Bot 不回复、一直"正在输入" | 没配模型或模型密钥不对；在 DSH 网页端的设置里检查 |
| 浏览器能开、App 连不上 | 浏览器可能走了不同的地址；确认手机和服务器网络互通（`curl` 一下同一个地址） |
| 想看 Bot 的聊天记录在哪 | `$DSH_HOME/bot/` 和 `$DSH_HOME/sessions/` |

## 8. 备份与升级

- **备份**：停掉服务，复制整个 `$DSH_HOME`（以及 Bot 的工作目录）。
- **升级 ds-bot**：`npx dsh plugin --profile web add ds-bot@<版本>`，重启网关。升级后用 App 过一遍：列表、聊天、设置、用量。
- **升级 DSH**：改 `package.json` 里的版本后 `npm i`，注意核对 ds-bot 声明的兼容版本。

## 9. 关于 Docker

上游 DS Bot 提供 Docker 镜像（见其仓库的 `docker/`），但镜像里的 `dsh web` 同样只有一次性令牌，没有认证层，**本项目没有在 Docker 部署上验证过网关**。思路上可以把 `ds-gateway.mjs` 放进镜像，把容器启动命令换成 `node ds-gateway.mjs -- dsh …`，只发布网关端口。自己试的话务必先在局域网内确认能登录，再考虑公网。
