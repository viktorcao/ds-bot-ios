import XCTest

/// 端到端测试连的服务器。地址和 Bot 名通过环境变量传入，没设地址就跳过（不会误连别人的机器）：
///
///     TEST_RUNNER_DSBOT_TEST_URL=http://192.168.1.10:8731 TEST_RUNNER_DSBOT_TEST_BOT=Chief xcodebuild … test
///
/// xcodebuild 会把 `TEST_RUNNER_` 前缀去掉后交给测试进程。测试默认假设服务器是局域网内、不要账号密码的。
enum TestServer {
    static var url: String { ProcessInfo.processInfo.environment["DSBOT_TEST_URL"] ?? "" }
    /// 发消息、看设置等用例使用的 Bot 名；默认是新团队一定有的主 Bot
    static var bot: String { ProcessInfo.processInfo.environment["DSBOT_TEST_BOT"] ?? "Chief" }
    /// 审批、提问用例用的只读权限测试 Bot（需要自己在服务器上建，见 README）
    static var approvalBot: String { ProcessInfo.processInfo.environment["DSBOT_TEST_APPROVAL_BOT"] ?? "ios-test" }

    /// 配好启动参数：预先填好服务器地址、固定深色外观
    static func configure(_ app: XCUIApplication) throws {
        try XCTSkipIf(url.isEmpty, "未设置 DSBOT_TEST_URL（xcodebuild 里写成 TEST_RUNNER_DSBOT_TEST_URL）")
        // 命令行参数会进入 UserDefaults 的参数域，等价于预先填好服务器地址
        app.launchArguments += ["-dsbot.url", url, "-dsbot.appearance", "dark"]
    }
}
