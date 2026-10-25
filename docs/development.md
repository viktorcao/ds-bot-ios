# 开发指南

## 环境

- macOS + Xcode（作者用 Xcode 27 beta 验证；iOS 17.0 为最低部署版本），无第三方依赖。
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)：`brew install xcodegen`。工程由 `project.yml` 生成，`DSBot.xcodeproj` 不入库。
- **新增或改名源文件后必须重新 `xcodegen generate`**，否则文件不会被编译进目标。判断测试有没有真正执行，看 `Executed N tests` 的 N 不为 0。

```bash
xcodegen generate
open DSBot.xcodeproj
```

## 签名与包名

> 装到真机的完整步骤见 [install-iphone.md](install-iphone.md)，下面是要点。

默认包名是 `com.example.dsbot`、没有签名团队，所以直接在真机上运行会失败。用你自己的账号覆盖，新建不入库的 `Config/Local.xcconfig`：

```
DSBOT_BUNDLE_ID = com.yourname.dsbot
DEVELOPMENT_TEAM = ABCDE12345
```

Team ID 在 developer.apple.com → Membership 里。钥匙串的 service 取自包名，换包名后需要重新登录一次。

模拟器编译（不需要签名）：

```bash
xcodebuild -project DSBot.xcodeproj -scheme DSBot -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

真机命令行安装：

```bash
DEV=<设备标识，xcrun devicectl list devices 里查>
xcodebuild -project DSBot.xcodeproj -scheme DSBot -configuration Debug -destination "id=$DEV" \
  -derivedDataPath build-device -allowProvisioningUpdates build
xcrun devicectl device install app --device $DEV build-device/Build/Products/Debug-iphoneos/DSBot.app
```

首次安装后手机会提示"未受信任的开发者"：设置 → 通用 → VPN 与设备管理 → 开发者 App → 信任。免费个人账号签名的 App 7 天后过期。

## 测试

只有端到端 UI 测试，连真实服务器，**会在 Bot 的聊天里留下记录并消耗模型调用**。服务器地址和 Bot 名通过环境变量传入（xcodebuild 要加 `TEST_RUNNER_` 前缀），没设 `DSBOT_TEST_URL` 的用例会被跳过：

```bash
TEST_RUNNER_DSBOT_TEST_URL=http://192.168.1.10:8731 \
TEST_RUNNER_DSBOT_TEST_BOT=Chief \
xcodebuild -project DSBot.xcodeproj -scheme DSBot -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO test -only-testing:DSBotUITests/UsageScreenTests
```

测试假设服务器在局域网、**没有设账号密码**（启动参数只能预填地址）。

| 变量 | 默认 | 含义 |
|---|---|---|
| `DSBOT_TEST_URL` | 空（跳过） | 服务器地址 |
| `DSBOT_TEST_BOT` | `Chief` | 发消息、停止、输入栏用例使用的 Bot |
| `DSBOT_TEST_APPROVAL_BOT` | `ios-test` | 审批、提问用例使用的只读权限 Bot |

| 用例 | 做什么 |
|---|---|
| `SendMessageTests` | 发一句话，断言用户消息立刻出现，并在 90 秒内收到精确等于 `pong-<随机数>` 的回复。断言必须"精确等于"：用户消息里也含这段文字，用"包含"会不等回复就误判通过 |
| `BotSettingsTests` | 用 App 新建临时 Bot → 改标签、权限、说明并保存 → 重新打开确认已持久化 → 复制 → 把两个都删掉；不碰其他 Bot |
| `ComposerOptionsTests` | 输入栏展开、选项面板 |
| `UsageScreenTests` | 只读，打开用量页截图 |
| `StopButtonTests` | 让 Bot 执行 `sleep 40`，运行中出现停止键，点击后显示"已停止"，再等 45 秒确认没有继续回复 |
| `ApprovalCardTests` | 对**只读权限**的 Bot 下达写文件指令，断言出现审批卡片；点"允许一次"回 `done-<随机数>`，点"拒绝"回 `denied-<随机数>` |
| `QuestionCardTests` | 让 Bot 用 `ask_user` 提一个 A/B 单选题，点 B 后 Bot 回 `picked-B-<随机数>` |

准备审批 / 提问用例的测试 Bot（服务器上做一次）：创建名为 `ios-test` 的 Bot，权限设为"仅可查看（read-only）"，说明写"用户让你执行 shell 命令时直接用 shell 工具执行；成功只回复 done，被拒绝或失败只回复 denied"。

已知：`StopButtonTests` 在作者的环境里失败，原因没有查清（在未改动的提交上同样失败，可能与服务器端的取消行为有关）。

不需要真实模型就能验证的最小路径：用 [server/ds-gateway.mjs](../server/ds-gateway.mjs) 起一个只有 Chief 的空团队，跑 `UsageScreenTests`，能确认登录、列表、设置面板和网关都是通的。

## 代码结构

```
DSBot/
├── DSBotApp.swift          入口
├── Core/
│   ├── APIClient.swift     HTTP / 基本认证 / 令牌握手 / WebSocket
│   ├── TeamStore.swift     全部状态（@Observable）：轮询、聊天缓冲、审批、通知、离线
│   ├── EventsChannel.swift 单聊审批的事件通道（WebSocket）
│   ├── Models.swift        Bot / ChatItem / Approval 等模型
│   ├── ChatCache.swift     聊天与状态缓存（Caches 目录，带大小上限）
│   ├── Notifier.swift      本地通知
│   ├── Keychain.swift      密码
│   ├── CharacterArt.swift  头像绘制（读 Avatars.json）
│   └── JSONValue.swift     宽松的 JSON 读取
├── UI/
│   ├── RootView.swift      列表首页 ⇄ 聊天页的推入与左边缘返回
│   ├── BotListView.swift   首页 Bot 列表
│   ├── ChatView.swift      聊天、输入栏、运行指示
│   ├── Cards.swift         审批卡、提问卡
│   ├── MarkdownView.swift  Markdown 渲染（含表格）
│   ├── BotProfileView.swift / BotSettingsView.swift   Bot 资料与设置、定时任务
│   ├── AccountSheets.swift 账号面板、新建 Bot
│   ├── UsageView.swift     用量
│   ├── LoginView.swift
│   └── Theme.swift
├── Avatars.json            头像角色表（从 DS Bot 网页端导出）
└── Assets.xcassets
DSBotUITests/               端到端 UI 测试
server/ds-gateway.mjs       认证网关
Config/Shared.xcconfig      包名、签名团队的默认值
Icon/                       图标源文件
```

## 约定

- 代码注释、界面文案、提交信息用中文。
- `TeamStore` 是 `@Observable`：Observation 不比较相等，**赋值前先比较**，否则每次赋值都会让所有读取它的页面重绘（轮询每 1.2 秒一次，这会直接造成卡顿）。
- 聊天消息的 id 取决于内容指纹（`ChatItem.base`）加出现序号，不依赖数组下标，窗口滑动、加载更早消息时才能和已有内容对齐。
- 界面颜色按 Bot 的配色，用户气泡文字在浅色底上自动换黑字（`Bot.onTint`）。

## 图标

图标是 DS Bot 里 Chief 头像的那只蓝色小鲸鱼（取自网页端头像的 SVG，颜色 `#6A84FF`），深色渐变底、居中。源文件在 `Icon/`：`whale-source.svg`（网页端原图）、`icon.svg`（合成稿）、`icon-1024.png`（导出，RGB 无透明通道）；同一张图放进 `Assets.xcassets` 的 `AppIcon` 与登录页用的 `Logo`。

重新导出 PNG 时视口必须固定为 1024×1024，否则浏览器会把图缩小并留黑边。
