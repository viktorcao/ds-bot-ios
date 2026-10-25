import XCTest

/// 输入栏：空闲时是收起的胶囊（没有“+”和发送键），聚焦后展开；“+”打开模型 / 权限选项面板（只看不改）。
final class ComposerOptionsTests: XCTestCase {
    func testComposerExpandsAndShowsOptions() throws {
        let app = XCUIApplication()
        try TestServer.configure(app)
        app.launch()
        let menu = app.buttons["appSettingsButton"]
        XCTAssertTrue(menu.waitForExistence(timeout: 30))
        let row = app.buttons["botRow-\(TestServer.bot)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()

        let field = app.descendants(matching: .any)["composerField"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["composerOptionsButton"].exists, "空闲收起时不应显示“+”")
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "collapsed"; a.lifetime = .keepAlways; add(a)

        field.tap()
        let plus = app.buttons["composerOptionsButton"]
        XCTAssertTrue(plus.waitForExistence(timeout: 3), "聚焦后应展开并显示“+”")
        let b = XCTAttachment(screenshot: app.screenshot()); b.name = "expanded"; b.lifetime = .keepAlways; add(b)

        plus.tap()
        XCTAssertTrue(app.staticTexts["模型"].waitForExistence(timeout: 3), "选项面板应显示模型分区")
        // 面板默认半高，模型很多时权限在折叠线以下，上滑到可见
        for _ in 0..<4 where !app.staticTexts["权限"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["权限"].exists, "选项面板应显示权限分区")
        let c = XCTAttachment(screenshot: app.screenshot()); c.name = "options"; c.lifetime = .keepAlways; add(c)
        app.buttons["完成"].tap()
    }
}
