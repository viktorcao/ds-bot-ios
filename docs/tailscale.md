# 用 Tailscale 在外面访问（推荐）

[Tailscale](https://tailscale.com) 把你的服务器和手机放进同一个私有虚拟网络（tailnet）。服务器**不用开任何公网端口、不用域名、不用证书、不用备案**，只有登录了你账号的设备才能访问。对个人使用，这是比"反向代理 + HTTPS"更省事也更安全的做法。

> 本文的步骤没有在真实的 Tailscale 环境里完整跑过（作者的开发机没有装 Tailscale）。网关在 tailnet 来源下的行为（见 [第 3 步](#3-网关必须设账号密码)）已经用模拟请求验证过；Tailscale 自身的命令请以 `tailscale --help` 和[官方文档](https://tailscale.com/kb)为准。

## 1. 服务器加入 tailnet

先按 [server-setup.md](server-setup.md) 把 DSH + 网关跑通（局域网内能用再往下）。

- **Linux**：
  ```bash
  curl -fsSL https://tailscale.com/install.sh | sh
  sudo tailscale up
  ```
  终端会打印一个登录链接，在浏览器里用你的账号登录并授权。
- **macOS**：从 App Store 或官网安装 Tailscale，登录。
- **NAS（群晖、飞牛、威联通等）**：在应用中心搜 Tailscale，或按官方的 NAS 文档安装。装在容器里时要让网关能被它访问到（同一台机器上 `100.x.y.z:8731` 能通即可）。

查看这台机器在 tailnet 里的地址：

```bash
tailscale ip -4          # 例如 100.101.102.103
tailscale status         # 列出所有设备，以及它们的 MagicDNS 名字
```

## 2. 手机加入同一个 tailnet

1. App Store 搜索并安装 **Tailscale**。
2. 打开后用**同一个账号**登录，允许添加 VPN 配置。
3. 打开开关，状态变成已连接（手机状态栏会出现 VPN 图标）。

手机必须保持 Tailscale 连接，才能访问服务器。如果想让它在需要时自动连，可以在 Tailscale 设置里开启"按需连接"（On Demand）一类的选项（名称以当前版本为准）。

## 3. 网关必须设账号密码

**这一步容易踩坑。** 网关在没设账号密码时，只给"内网地址"的客户端发登录令牌，而 tailnet 的地址（`100.64.0.0/10`）不在它认定的内网范围里。所以不设密码的话，手机通过 Tailscale 访问会得到 403："未配置认证时，只允许从局域网访问"。

直接设账号密码即可，认证过的客户端不受这个限制。这也是应该做的：tailnet 里还有你其他的设备，多一层密码更稳妥。

```bash
DS_GATEWAY_USER=me DS_GATEWAY_PASS='换成强随机密码' \
  node ds-gateway.mjs -- node_modules/.bin/dsh --profile web --no-open --host 127.0.0.1 --port '{PORT}'
```

想让网关**只监听 tailnet**、不暴露在局域网和公网，把监听地址设成 Tailscale 给的地址：

```bash
DS_GATEWAY_HOST=100.101.102.103 …      # tailscale ip -4 的输出
```

> 注意：服务器重启后 Tailscale 要先起来，网关才能绑到这个地址；用 systemd 时在 `After=` 里加上 `tailscaled.service`。

## 4. 在 App 里连接

有两种填法，选一种：

### 方案 A：直接用 tailnet 地址（最简单）

App 登录页：

- **服务器地址**：`http://100.101.102.103:8731`（换成你的 `tailscale ip -4`），必须写 `http://`。
- **用户名 / 密码**：第 3 步设的账号密码。

虽然是 `http://`，但流量在 tailnet 里已经被 WireGuard 加密。App 的 ATS 配置对 IP 地址允许明文 HTTP（局域网 IP 已验证；`100.x` 地址按同一规则应该也行，但没在真实 tailnet 里试过）。

用 MagicDNS 名字时要注意：简称（如 `http://myserver:8731`）按"不带域名的主机名"处理，理论上可以用（未验证）；带 `.ts.net` 的完整域名是公网域名格式，App 会要求 HTTPS，直接写 `http://` 会被拦，改用方案 B。

### 方案 B：HTTPS（`tailscale serve`）

先在 [Tailscale 管理后台](https://login.tailscale.com/admin/dns)的 DNS 页面启用 MagicDNS 和 HTTPS Certificates，然后在服务器上：

```bash
# 网关只监听本机，由 tailscale 提供 HTTPS 入口
DS_GATEWAY_HOST=127.0.0.1 DS_GATEWAY_BEHIND_PROXY=1 DS_GATEWAY_USER=me DS_GATEWAY_PASS='…' \
  node ds-gateway.mjs -- node_modules/.bin/dsh --profile web --no-open --host 127.0.0.1 --port '{PORT}'

tailscale serve --bg 8731          # 把 https://<机器名>.<tailnet>.ts.net 转发到本机 8731
tailscale serve status             # 确认地址
```

App 里填 `https://<机器名>.<tailnet>.ts.net`（`tailscale serve status` 里显示的地址）。证书由 Tailscale 签发，iOS 直接信任。

> **不要用 `tailscale funnel`。** Funnel 会把服务暴露到公网互联网，等于绕过了 tailnet 的保护。本项目不需要它。

## 5. 收紧访问范围（可选）

默认 tailnet 里所有设备互通。想让服务器只被你的手机访问，可以在管理后台的 Access controls 里写 ACL 或用标签（tags），只放行手机到服务器的 8731 端口。参见官方文档的 ACL 一节。

## 6. 国内网络

Tailscale 的登录和协调服务器在境外，国内网络下登录可能慢或失败，设备之间优先尝试直连（打洞），打不通时走中继服务器，质量不稳定。**这部分作者没有实测，需要你自己试。** 如果效果不好：

- 手机和服务器都能直连打洞成功时通常没问题（`tailscale status` 里看对端是 `direct` 还是 `relay`）；
- 可以自建 [Headscale](https://github.com/juanfont/headscale)（Tailscale 控制服务器的开源实现）和自己的中继；
- 或者改用 WireGuard 自建、或回到 [反向代理 + HTTPS](server-setup.md#4-https) 方案。

## 排错

| 现象 | 处理 |
|---|---|
| App 提示 403 "只允许从局域网访问" | 网关没设账号密码，见第 3 步 |
| App 连不上，浏览器也打不开 | 手机上的 Tailscale 没连上；服务器上 `tailscale status` 看是否在线 |
| 手机能 ping 通但 App 提示超时 | 网关绑的地址不对（`DS_GATEWAY_HOST`），或服务器防火墙拦了 tailscale0 网卡的 8731 端口 |
| `http://xxx.ts.net:8731` 被 App 拒绝 | 带 `.ts.net` 的域名要求 HTTPS，改用方案 B，或改填 `100.x` 地址 |
| 方案 B 报证书错误 | 管理后台没启用 HTTPS Certificates，或没用 `tailscale serve` 显示的完整域名 |
| 切到蜂窝网络后断开 | 手机上的 Tailscale 被系统关闭了，检查 VPN 开关 |
