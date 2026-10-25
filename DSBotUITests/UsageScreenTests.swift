import XCTest

/// 只读：打开 设置 → 用量，截图并检查关键元素。
final class UsageScreenTests: XCTestCase {
    func testUsageScreen() throws {
        let app = XCUIApplication()
        try TestServer.configure(app)
        app.launch()
        let menu = app.buttons["appSettingsButton"]
        XCTAssertTrue(menu.waitForExistence(timeout: 30))
        menu.tap()
        sleep(2)
        let d = XCTAttachment(screenshot: app.screenshot()); d.name = "after-tap-settings"; d.lifetime = .keepAlways; add(d)
        // 设置面板里的“用量”入口是 NavigationLink：用 any 类型按标识或文字查找，避免依赖它被暴露成 button 还是 cell
        let usage = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'usageLink' OR label == '用量'")).firstMatch
        if !usage.waitForExistence(timeout: 10) { print("HIERARCHY:\n" + app.debugDescription) }
        XCTAssertTrue(usage.exists, "设置里应有用量入口"); usage.tap()
        XCTAssertTrue(app.staticTexts["Token 走势"].waitForExistence(timeout: 20), "应显示 Token 走势")
        XCTAssertTrue(app.staticTexts["缓存命中率"].exists)
        sleep(1)
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "usage-7d"; a.lifetime = .keepAlways; add(a)
        app.buttons["30 天"].tap(); sleep(1)
        let b = XCTAttachment(screenshot: app.screenshot()); b.name = "usage-30d"; b.lifetime = .keepAlways; add(b)
    }
}
