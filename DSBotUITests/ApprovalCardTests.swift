import XCTest

/// 端到端：对只读权限的测试 Bot（`DSBOT_TEST_APPROVAL_BOT`，默认 `ios-test`）下达写文件指令，Bot 会请求提权审批，
/// App 里应出现审批卡片；点“允许一次 / 拒绝”后 Bot 按结果回复。
/// 审批走 DSH 的 `$events` WebSocket 通道，不是 /api/bot。
/// 每个用例会让测试 Bot 跑几轮模型，耗时约半分钟。
final class ApprovalCardTests: XCTestCase {
    private func launchAndOpen(_ botName: String) throws -> XCUIApplication {
        let app = XCUIApplication()
        try TestServer.configure(app)
        app.launch()
        let menu = app.buttons["appSettingsButton"]
        XCTAssertTrue(menu.waitForExistence(timeout: 30), "连接服务器后应该出现聊天页")
        let row = app.buttons["botRow-\(botName)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "抽屉里应该有 \(botName)")
        row.tap()
        return app
    }

    private func send(_ text: String, in app: XCUIApplication) {
        let field = app.descendants(matching: .any)["composerField"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(text)
        app.buttons["sendButton"].tap()
    }

    private func run(allow: Bool) throws {
        let app = try launchAndOpen(TestServer.approvalBot)
        let stamp = Int(Date().timeIntervalSince1970) % 100000
        send("请用 shell 工具执行：touch /tmp/dsbot-ios-\(stamp).txt。成功后只回复 done-\(stamp)；被拒绝则只回复 denied-\(stamp)", in: app)

        // 1) 出现审批卡片，并且按钮可点（说明事件通道已同步到 eventId）
        let card = app.descendants(matching: .any)["approvalCard"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 120), "应出现审批卡片")
        let button = app.buttons[allow ? "approveButton" : "rejectButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        let enabled = NSPredicate(format: "isEnabled == true")
        expectation(for: enabled, evaluatedWith: button)
        waitForExpectations(timeout: 20)

        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = allow ? "approval-card-before-allow" : "approval-card-before-reject"
        before.lifetime = .keepAlways
        add(before)

        // 2) 点击后卡片消失
        button.tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: card)
        waitForExpectations(timeout: 20)

        // 3) Bot 按审批结果回复（精确匹配，避免和用户消息里的同名文字混淆）
        let expected = allow ? "done-\(stamp)" : "denied-\(stamp)"
        let reply = app.staticTexts[expected]
        XCTAssertTrue(reply.waitForExistence(timeout: 120), "Bot 应回复 \(expected)")

        let after = XCTAttachment(screenshot: app.screenshot())
        after.name = allow ? "after-allow" : "after-reject"
        after.lifetime = .keepAlways
        add(after)
    }

    func testAllowOnce() throws { try run(allow: true) }
    func testReject() throws { try run(allow: false) }
}
