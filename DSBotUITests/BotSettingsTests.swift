import XCTest

/// 端到端：新建临时 Bot → 修改资料/权限/说明并保存 → 重新打开确认已保存 → 复制 → 删除两个。
/// 只动自己创建的临时 Bot；创建时 Bot 会做一次自我介绍（一次模型调用）。
final class BotSettingsTests: XCTestCase {
    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func openDrawer(_ app: XCUIApplication) {
        let menu = app.buttons["appSettingsButton"]
        XCTAssertTrue(menu.waitForExistence(timeout: 30))
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        // 小步上拖（约 20% 屏高）：整屏快滑在长页面上会一下滑过目标
        var tries = 0
        while !element.isHittable && tries < 20 {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            from.press(forDuration: 0.1, thenDragTo: to)
            tries += 1
        }
    }

    func testLifecycle() throws {
        let app = XCUIApplication()
        try TestServer.configure(app)
        app.launch()
        let stamp = Int(Date().timeIntervalSince1970) % 100000
        let name = "tmp\(stamp)"

        // 1) 新建
        openDrawer(app)
        app.buttons["newBotButton"].tap()
        let nameField = app.textFields["newBotName"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        nameField.tap(); nameField.typeText(name)
        app.buttons["newBotCreate"].tap()

        // 2) 打开设置，改标签 / 权限 / 说明
        let settingsButton = app.buttons["botSettingsButton"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 30))
        // 创建后会自动切到新 Bot，标题里应出现它的名字
        XCTAssertTrue(app.buttons["\(name) 资料"].waitForExistence(timeout: 30), "应切换到新建的 Bot")
        settingsButton.tap()
        app.buttons["editBotButton"].tap()   // 资料页 → 编辑
        let role = app.textFields["botRoleField"]
        XCTAssertTrue(role.waitForExistence(timeout: 10))
        shot(app, "settings-top")
        role.tap(); role.typeText("测试标签")
        app.buttons["仅可查看"].tap()
        let editor = app.textViews["instructionsEditor"]
        scrollTo(editor, in: app)
        editor.tap(); editor.typeText("只回答测试问题")
        shot(app, "settings-instructions")
        let save = app.buttons["saveBotSettings"]
        XCTAssertTrue(save.isEnabled, "有改动时保存按钮应可用")
        save.tap()
        // 保存后设置页关闭，回到资料页；关掉资料页才回到聊天
        let closeProfile = app.buttons["关闭"]
        XCTAssertTrue(closeProfile.waitForExistence(timeout: 15), "保存后设置页应关闭，露出资料页")
        closeProfile.tap()
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 15))

        // 3) 重新打开，确认保存成功（读的是服务器的数据）
        settingsButton.tap()
        app.buttons["editBotButton"].tap()
        let role2 = app.textFields["botRoleField"]
        XCTAssertTrue(role2.waitForExistence(timeout: 10))
        XCTAssertEqual(role2.value as? String, "测试标签", "标签应已保存")
        XCTAssertTrue(app.buttons["仅可查看"].isSelected || (app.buttons["仅可查看"].value as? String) == "1", "权限应为仅可查看")
        let editor2 = app.textViews["instructionsEditor"]
        scrollTo(editor2, in: app)
        XCTAssertEqual(editor2.value as? String, "只回答测试问题", "说明应已保存")
        shot(app, "settings-reopened")

        // 4) 复制一份
        let dup = app.buttons["duplicateBotButton"]
        scrollTo(dup, in: app)
        shot(app, "settings-bottom")
        dup.tap()
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 30))

        // 5) 删除副本和原件（当前选中的是副本）
        try deleteCurrent(app)
        openDrawer(app)
        let original = app.buttons["botRow-\(name)"]
        XCTAssertTrue(original.waitForExistence(timeout: 10), "原 Bot 应仍在")
        original.tap()
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        try deleteCurrent(app)

        // 6) 抽屉里不再有这两个临时 Bot
        openDrawer(app)
        XCTAssertTrue(app.buttons["botRow-Chief"].waitForExistence(timeout: 10))
        let leftovers = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "botRow-\(name)"))
        XCTAssertEqual(leftovers.count, 0, "临时 Bot 应已全部删除")
    }

    private func deleteCurrent(_ app: XCUIApplication) throws {
        app.buttons["botSettingsButton"].tap()
        app.buttons["editBotButton"].tap()
        let del = app.buttons["deleteBotButton"]
        XCTAssertTrue(app.buttons["saveBotSettings"].waitForExistence(timeout: 10))
        scrollTo(del, in: app)
        del.tap()
        let confirm = app.buttons["删除"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.buttons["appSettingsButton"].waitForExistence(timeout: 20))
    }
}
