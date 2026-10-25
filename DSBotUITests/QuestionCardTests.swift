import XCTest

/// 端到端：让测试 Bot（`DSBOT_TEST_APPROVAL_BOT`，默认 `ios-test`）用 ask_user 工具向用户提问，App 里应出现提问卡片；
/// 点选项后 Bot 收到回答并按约定回复。
final class QuestionCardTests: XCTestCase {
    func testPickOption() throws {
        let app = XCUIApplication()
        try TestServer.configure(app)
        app.launch()
        let menu = app.buttons["appSettingsButton"]
        XCTAssertTrue(menu.waitForExistence(timeout: 30))
        let row = app.buttons["botRow-\(TestServer.approvalBot)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        let stamp = Int(Date().timeIntervalSince1970) % 100000
        let field = app.descendants(matching: .any)["composerField"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("请调用 ask_user 工具向我提问，问题是：选哪个？，提供两个单选选项：A 和 B。我回答之后，你只回复 picked-<我选的选项>-\(stamp)，不要加别的内容。")
        app.buttons["sendButton"].tap()

        // 1) 出现提问卡片，带有两个选项
        let card = app.descendants(matching: .any)["questionCard"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 120), "应出现提问卡片")
        let optionB = app.buttons["option-B"]
        XCTAssertTrue(optionB.waitForExistence(timeout: 5), "卡片里应有选项 B")
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "question-card"
        before.lifetime = .keepAlways
        add(before)

        // 2) 选 B：卡片消失
        optionB.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: card)
        waitForExpectations(timeout: 20)

        // 3) Bot 收到回答并回复（精确匹配）
        let reply = app.staticTexts["picked-B-\(stamp)"]
        XCTAssertTrue(reply.waitForExistence(timeout: 120), "Bot 应回复 picked-B-\(stamp)")
        let after = XCTAttachment(screenshot: app.screenshot())
        after.name = "after-answer"
        after.lifetime = .keepAlways
        add(after)
    }
}
