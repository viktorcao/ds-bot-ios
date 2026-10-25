# 编译并安装到 iPhone

App 没有上架 App Store，需要自己用 Xcode 编译并装到手机上。**不需要付费的开发者账号**：免费的 Apple ID 就能装到自己的 iPhone，代价是签名每 7 天过期，需要重新装一次（见 [免费账号的限制](#免费账号的限制)）。

## 准备

- 一台 Mac，装好 Xcode（作者用 Xcode 27 beta 验证；iOS 最低 17.0）。
- 一部 iPhone（iOS 17 或更新）和一根数据线。
- 一个 Apple ID。免费的就行，登录到 Xcode：Xcode → Settings → Accounts → 左下角 `+` → Apple ID。
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)：`brew install xcodegen`。

## 步骤

### 1. 取代码并生成工程

```bash
git clone https://github.com/viktorcao/ds-bot-ios.git
cd ds-bot-ios
xcodegen generate
```

### 2. 写自己的包名和签名团队

新建 `Config/Local.xcconfig`（已被 `.gitignore` 忽略，不会提交）：

```
DSBOT_BUNDLE_ID = com.yourname.dsbot
DEVELOPMENT_TEAM = ABCDE12345
```

- **包名要全球唯一**：苹果按包名注册 App ID，`com.example.dsbot` 已被占用或不可用，请换成你自己的反向域名，如 `com.zhangsan.dsbot`。
- **Team ID** 是 10 位大小写字母和数字。查法（任选一种）：
  - 付费账号：developer.apple.com → Membership details → Team ID。
  - 免费账号：先在 Xcode 里登录 Apple ID 并至少签名过一次任意项目，然后在终端运行
    ```bash
    security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject
    ```
    输出里的 `OU=XXXXXXXXXX` 就是 Team ID。
  - 或：打开生成的 `DSBot.xcodeproj` → 选 DSBot 目标 → Signing & Capabilities → Team 里选你的账号，Xcode 会自动写入，然后用 `grep -m1 DEVELOPMENT_TEAM DSBot.xcodeproj/project.pbxproj` 读出来，填进 `Local.xcconfig` 以后重新 `xcodegen generate`（直接在 Xcode 里选的团队会在重新生成工程时丢失）。

改完重新生成一次：

```bash
xcodegen generate
```

### 3. 打开手机的开发者模式

iPhone：设置 → 隐私与安全性 → 最下面的 **开发者模式** → 打开 → 按提示重启 → 重启后确认。第一次用数据线连 Mac 时，手机上选"信任此电脑"。（没有"开发者模式"这一项时，先用 Xcode 连上手机，它就会出现。）

### 4A. 用 Xcode 安装（最简单）

1. `open DSBot.xcodeproj`。
2. 顶部设备选择器里选你的 iPhone。
3. 点 DSBot 目标 → Signing & Capabilities，确认 **Automatically manage signing** 打勾、Team 是你的账号、没有红色报错。
4. 按 ⌘R。第一次会提示钥匙串密码，选"始终允许"。

### 4B. 用命令行安装

```bash
# 查设备标识（CoreDevice ID）
xcrun devicectl list devices

DEV=<上面查到的标识>
xcodebuild -project DSBot.xcodeproj -scheme DSBot -configuration Debug \
  -destination "id=$DEV" -derivedDataPath build-device -allowProvisioningUpdates build
xcrun devicectl device install app --device $DEV \
  build-device/Build/Products/Debug-iphoneos/DSBot.app
```

`-allowProvisioningUpdates` 让 xcodebuild 自动创建描述文件，所以 Xcode 里必须已经登录了 Apple ID。

### 5. 信任开发者并启动

第一次打开 App 会提示"未受信任的开发者"：

iPhone：设置 → 通用 → VPN 与设备管理 → 开发者 App 下点你的 Apple ID → **信任**。

然后回到桌面打开 **DS Bot**，登录页填服务器地址即可（见 [服务端部署](server-setup.md#6-在-app-里连接)）。

## 免费账号的限制

- **签名 7 天过期**：到期后 App 打不开（图标变灰或闪退）。重新执行 4A 或 4B 即可，聊天缓存和登录信息保留在手机上。
- 同一个免费账号一周内最多注册 10 个 App ID，同时最多装 3 个自签 App。反复改包名会很快用完额度。
- 没有推送，也没有 TestFlight。
- 想免去每周重装：付费开发者账号（99 美元 / 年）签名一年有效，也可以用 TestFlight 分发；或使用 AltStore / SideStore 之类的第三方工具自动续签（与本项目无关，自行评估风险）。

## 常见问题

| 现象 | 处理 |
|---|---|
| `Failed to register bundle identifier` / 包名不可用 | 包名被别人注册了，换一个更独特的 `DSBOT_BUNDLE_ID`，重新 `xcodegen generate` |
| `No Account for Team` / `No signing certificate` | Xcode 里没登录 Apple ID，或 `DEVELOPMENT_TEAM` 填错；回到第 2 步核对 |
| 设备选择器里没有我的 iPhone | 数据线连接、手机解锁并点"信任"、开发者模式已开；Xcode → Window → Devices and Simulators 里能看到手机才行 |
| `Developer Mode disabled` | 回到第 3 步 |
| `The request was denied by service delegate` / `invalid code signature` | 手机上还没信任开发者，见第 5 步 |
| 编译报 `Cannot find 'xxx' in scope`，且文件是新加的 | 忘了重新 `xcodegen generate` |
| iOS 版本高于 Xcode 支持范围 | 升级 Xcode；或者暂时用模拟器 |
| 打开 App 后连不上局域网服务器 | 首次会弹"本地网络"权限，选允许；点了不允许的话在 设置 → 隐私与安全性 → 本地网络 里打开 DS Bot |
| 想先在模拟器里试 | 不需要签名：`xcodebuild … -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO build`，或在 Xcode 里选模拟器运行。注意模拟器访问不到你手机上才能访问的内网地址，填服务器的局域网地址通常也能通 |
