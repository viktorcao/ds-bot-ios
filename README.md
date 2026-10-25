# DS Bot for iOS

[DeepSeek Bot（DS Bot）](https://github.com/Fei2411/DeepSeek-Bot) 的原生 iOS 客户端。DS Bot 是 [DeepSeek Harness（DSH）](https://github.com/deepseek-ai/deepseek-harness) 的多 Bot 插件；这个 App 让你在手机上和自己服务器上的 Bot 团队聊天、审批工具调用、回答 Bot 的提问、管理 Bot 和查看用量。

SwiftUI 编写，iOS 17+，无第三方依赖。交互参照 Grok Bot：整页 Bot 列表、聊天页从右侧推入、玻璃质感顶栏、按 Bot 配色的气泡。

> **这是社区项目，不是 DeepSeek 官方产品**，与 DeepSeek、DS Bot 作者没有隶属或背书关系。"DeepSeek"等名称归各自所有者，这里只用来说明本项目对接的对象。
>
> **本项目只是客户端，依赖上游服务端才能使用**：需要你自己部署 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（`dsh web`）并安装 [DeepSeek Bot](https://github.com/Fei2411/DeepSeek-Bot)（`ds-bot` 插件）。没有它们，App 无处可连。详见 [依赖与来源](#依赖与来源)。
>
> Bot 能在服务器上读写文件、执行命令。**把服务器暴露到公网之前，务必读完 [认证与安全](#认证与安全)。**

## 它是怎么工作的

```
iPhone App ──HTTP(S) + 基本认证──▶ ds-gateway（认证 + 换取登录令牌）──回环──▶ dsh web + ds-bot 插件
```

App **不是**独立的聊天服务，它连的是你自己部署的 DSH。DSH 的网页端用一个接口 `POST /api/bot` 驱动 DS Bot，App 调用的是同一批端点（详见 [docs/protocol.md](docs/protocol.md)）。

要注意的一点：原版 `dsh web` 只在启动日志里打印**一次性登录链接**（`?token=…`），浏览器带着它访问一次、换到会话 Cookie 才能用，而且没有账号密码这一层。手机 App 读不到服务器日志，所以本仓库附带了一个很小的网关 [`server/ds-gateway.mjs`](server/ds-gateway.mjs)（无依赖的单个 Node 脚本）：它启动 `dsh web`、替 App 完成令牌登录，并可选加上基本认证和 HTTPS。

## 快速开始

三步：服务端 → 构建 App → 连接。

### 1. 服务端（约 5 分钟）

需要 Node.js 22.19+ 和 pnpm 10+。已验证组合：`@deepseek-ai/dsh 0.2.1-rc.2` + `ds-bot 0.2.1`。

```bash
mkdir ~/dsh-server && cd ~/dsh-server
npm init -y && npm i @deepseek-ai/dsh@0.2.1-rc.2
export DSH_HOME=~/.dsh                       # DSH 的数据目录（Bot 团队、聊天记录都在这里）
npx dsh plugin --profile web add ds-bot      # 安装 DS Bot 插件

# 把本仓库的 server/ds-gateway.mjs 复制到当前目录，然后启动：网关 + dsh web（账号密码换成你自己的）
DS_GATEWAY_USER=me DS_GATEWAY_PASS='换成强密码' \
  node ds-gateway.mjs -- node_modules/.bin/dsh --profile web --no-open --host 127.0.0.1 --port '{PORT}'
```

启动成功后日志会出现 `dsh web 已就绪`。然后用浏览器打开 `http://<服务器 IP>:8731`（输入上面的账号密码），在 DSH 里**先配好至少一个模型**，DS Bot 才能聊天。模型配置见 [DS Bot 文档的 Models 一节](https://github.com/Fei2411/DeepSeek-Bot/blob/main/ds-bot/README.md#models)。第一次打开团队时会自动创建一个叫 Chief 的主 Bot。

完整的部署说明（开机自启、HTTPS、反向代理、公网访问、排错）见 **[docs/server-setup.md](docs/server-setup.md)**。

### 2. 编译并安装到 iPhone

App 没有上架 App Store，需要自己用 Xcode 编译安装，免费的 Apple ID 就够（签名每 7 天过期，重装一次即可）。

```bash
brew install xcodegen
git clone https://github.com/<你的用户名>/ds-bot-ios.git && cd ds-bot-ios
printf 'DSBOT_BUNDLE_ID = com.yourname.dsbot\nDEVELOPMENT_TEAM = ABCDE12345\n' > Config/Local.xcconfig   # 换成你自己的
xcodegen generate
open DSBot.xcodeproj      # 选你的 iPhone，⌘R
```

包名必须全球唯一；手机要先打开"开发者模式"，第一次运行后到 设置 → 通用 → VPN 与设备管理 里信任自己的开发者。**完整步骤（怎么查 Team ID、命令行安装、免费账号限制、常见报错）见 [docs/install-iphone.md](docs/install-iphone.md)。**

### 3. 连接

打开 App，登录页填：

| 字段 | 填什么 |
|---|---|
| 服务器地址 | 局域网用 `http://192.168.1.10:8731`（**必须写 `http://`**）；公网用 `https://bot.example.com`。不写协议时 App 按 `https://` 处理 |
| 用户名 / 密码 | 网关启动时设的 `DS_GATEWAY_USER` / `DS_GATEWAY_PASS`；没设认证（仅局域网）就留空 |

密码只保存在这台 iPhone 的钥匙串里，退出登录会一并清除。

## 认证与安全

**Bot 可以执行命令、读写服务器上的文件。** 能登录 DSH 就等于能在你的服务器上执行代码，所以认证是整套方案的安全边界。

| 场景 | 做法 |
|---|---|
| 只在家里局域网用 | 网关可以不设账号密码。此时网关只给**内网地址**的客户端发登录令牌，公网来源一律 403。仍建议设密码 |
| 想在外面用 | 网关设 `DS_GATEWAY_USER` / `DS_GATEWAY_PASS`，**并且必须走 HTTPS**（App 对公网域名不允许明文 HTTP，且基本认证的密码是明文传输）。HTTPS 可由 Caddy / nginx 终结，也可以让网关直接加载证书 |
| 最稳妥 | 不暴露公网，用 [Tailscale](https://tailscale.com) 或 WireGuard 组内网，App 里填内网地址 |

增加认证的具体步骤、Caddy / nginx 配置、systemd 开机自启在 [docs/server-setup.md](docs/server-setup.md#认证)。几条硬性提醒：

- 网关目前是**单账号**，没有登录失败限速。公网使用请配 **强随机密码**，并在反向代理层加限速或用 fail2ban，或干脆只走 VPN。
- 不要把 `dsh web` 自己的端口直接映射到公网；只暴露网关的端口。
- Bot 的"完全权限"等于服务器用户的全部权限。给 Bot 配最小够用的权限，并用一个**专门的低权限系统用户**运行 DSH。

## 功能

- **Bot 列表**：头像、名称、角色标签、最后一条消息预览和时间；正在工作的置顶并带绿点；等你批准 / 回答 / 有未读各有标记；下拉刷新；顶部搜索过滤 Bot。
- **聊天**：Markdown（标题、列表、引用、表格、代码块可复制、行内样式和链接）；加载更早的消息；时间分隔；乐观发送，失败时文字放回输入框；运行状态（输入中 / 正在使用某工具 + 已运行时长）；长对话"回到底部"；左边缘右滑返回。
- **审批与提问**：工具调用审批卡（允许一次 / 拒绝，单聊与群聊两种通道），Bot 的提问卡（单选 / 多选 / 自由回答，可先收起）。
- **Bot 资料与设置**：头像（20 种形状 × 19 种颜色，与网页端一致）、名称、标签、模型与思考等级、权限（仅可查看 / 工作区内修改 / 完全权限）、工作文件夹、说明、记忆（查看 / 忘掉）、定时任务、设为主 Bot、复制、删除。
- **账号面板**：用量（24 小时到 12 个月，按 Bot / 模型堆叠）、全部定时任务、群聊列表、通知开关、外观（默认跟随系统）、聊天缓存上限与清除、退出登录。
- **离线**：聊天内容缓存在本机，断网也能冷启动查看历史；离线时顶部有提示并自动重连。
- **提醒**：审批和任务完成会发本地通知，**仅限 App 在前台或刚进后台的约 30 秒内**。没有苹果推送（APNs），不会在 App 被系统挂起后提醒你。
- **草稿**：每个 Bot 的输入框草稿自动保存。

### 没有做的

群聊的聊天记录（接口没有提供，只列出名称）、图片和附件、语音、聊天内搜索、技能 / 密钥管理、苹果推送、iPad 与横屏。

## 隐私

- 账号密码：钥匙串。
- 服务器地址、用户名、偏好、草稿、每个 Bot 的最后一条消息预览：UserDefaults。
- 聊天与状态缓存：App 的 Caches 目录（`dsbot-cache/`，可在设置里限制大小和清除）。
- 不含任何统计、遥测和第三方 SDK。App 只和你填的服务器通信。
- 退出登录会清除钥匙串、缓存、草稿和消息预览。

## 文档

| 文件 | 内容 |
|---|---|
| [docs/server-setup.md](docs/server-setup.md) | 服务端部署、认证、HTTPS、开机自启、排错 |
| [docs/protocol.md](docs/protocol.md) | App 用到的接口、登录流程、审批事件通道 |
| [docs/install-iphone.md](docs/install-iphone.md) | 编译并安装到 iPhone（签名、开发者模式、常见报错） |
| [docs/development.md](docs/development.md) | 构建、测试、代码结构 |
| [server/ds-gateway.mjs](server/ds-gateway.mjs) | 认证网关 |

## 依赖与来源

### 上游服务端（运行时必需）

| 项目 | 作用 | 许可 | 已验证版本 |
|---|---|---|---|
| [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（npm：[`@deepseek-ai/dsh`](https://www.npmjs.com/package/@deepseek-ai/dsh)） | Agent 运行环境，提供 `dsh web` 和插件系统 | 以其仓库为准 | `0.2.1-rc.2` |
| [DeepSeek Bot](https://github.com/Fei2411/DeepSeek-Bot)（npm：[`ds-bot`](https://www.npmjs.com/package/ds-bot)） | DSH 的多 Bot 插件：Bot 团队、聊天、记忆、用量等，也是 App 调用的 `/api/bot` 接口的提供方 | Apache-2.0 | `0.2.1` |

- 本仓库**不包含、不分发**上游的任何代码，只通过它们的网页端接口通信。这些接口不是公开稳定的 API，上游升级可能让 App 失效；遇到不兼容请先对照已验证版本。
- App 的功能完全取决于上游：Bot 怎么回复、用什么模型、有哪些设置，都是上游的行为，问题请先到上游确认。
- [`server/ds-gateway.mjs`](server/ds-gateway.mjs) 是本项目自己写的小网关，用来给 `dsh web` 加认证并代办登录，不是上游的一部分。

### 头像与图标素材

- **头像**：`DSBot/Avatars.json` 是 DS Bot 网页端头像的"角色表"（20 种形状、各自的路径与眼睛），从网页端导出，`DSBot/Core/CharacterArt.swift` 按同样的图层顺序把它画出来，目的是让手机上的头像和网页端完全一致。素材来自 [DeepSeek Bot](https://github.com/Fei2411/DeepSeek-Bot)，版权归其作者所有。
- **图标**：App 图标和登录页 Logo 用的是 DS Bot 里主 Bot Chief 的蓝色小鲸鱼头像（`Icon/whale-source.svg` 为网页端原图，`icon.svg` 是加了深色渐变底的合成稿）。同样来自上游，版权归其作者所有。
- 上游以 Apache-2.0 发布。本仓库保留这些素材的来源说明；**如果你要把这个项目用于商业用途或重新发布到 App Store，请先自行核对上游仓库的 LICENSE、NOTICE 和素材授权，并换成自己的图标**。
- 头像与图标与 DeepSeek 官方无关；"DeepSeek"等名称归各自所有者。

### 其他

- 颜色、布局的交互参考了 Grok Bot 的 iOS 应用，没有使用其代码或素材。
- 本项目没有第三方 Swift 依赖。

## 许可

本项目自己的代码以 [MIT](LICENSE) 发布。头像角色表和图标取自上游 DS Bot，不适用本项目的 MIT 许可，见 [依赖与来源](#依赖与来源)。
