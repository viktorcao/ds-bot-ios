import XCTest

/// 端到端：用局域网地址连真实服务器，选中测试 Bot（`DSBOT_TEST_BOT`，默认 Chief），发一句话并等回复。
/// 会在它的聊天里留下一问一答，并消耗一次模型调用。
final class SendMessageTests: XCTestCase {
    func testSendMessage() throws {
        let app = XCUIApplication()
        // 命令行参数会进入 UserDefaults 的参数域，等价于预先填好服务器地址
        try TestServer.configure(app)
        app.launch()

        let menu = app.buttons["appSettingsButton"]
        XCTAssertTrue(menu.waitForExistence(timeout: 30), "连接服务器后应该出现聊天页")

        let row = app.buttons["botRow-\(TestServer.bot)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "列表里应该有测试 Bot")
        row.tap()

        let field = app.descendants(matching: .any)["composerField"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        let stamp = Int(Date().timeIntervalSince1970) % 100000
        let message = "iOS 测试 \(stamp)：请只回复 pong-\(stamp)，不要加别的内容"
        field.typeText(message)

        let send = app.buttons["sendButton"]
        XCTAssertTrue(send.isEnabled)
        send.tap()

        // 1) 自己的消息立刻出现（乐观发送），并且发送后输入框被清空
        let mine = app.staticTexts[message]
        XCTAssertTrue(mine.waitForExistence(timeout: 10), "发送后应立即显示用户消息")

        // 2) Bot 的回复在 90 秒内出现。必须精确等于 "pong-<stamp>"：
        //    用户那条消息也包含这段文字，用“包含”会不等回复就误判通过。
        let reply = app.staticTexts["pong-\(stamp)"]
        let start = Date()
        XCTAssertTrue(reply.waitForExistence(timeout: 90), "应收到 Bot 的回复（等待了 \(Int(Date().timeIntervalSince(start))) 秒）")
        XCTAssertNotEqual(reply.label, message, "回复不能是用户自己的消息")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "after-reply"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
