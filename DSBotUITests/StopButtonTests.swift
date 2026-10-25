import XCTest

/// 端到端：对测试 Bot 下达一个耗时任务，运行中发送键变成常驻的停止键；点击后界面立刻显示“已停止”，
/// 并且之后 Bot 真的没有继续回复（会等待约 40 秒来证明“停止”是真的，而不是只改了界面）。
final class StopButtonTests: XCTestCase {
    func testStopRunningTask() throws {
        let app = XCUIApplication()
        try TestServer.configure(app)
        app.launch()
        let menu = app.buttons["appSettingsButton"]
        XCTAssertTrue(menu.waitForExistence(timeout: 30))
        let row = app.buttons["botRow-\(TestServer.bot)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()

        let stamp = Int(Date().timeIntervalSince1970) % 100000
        let field = app.descendants(matching: .any)["composerField"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap()
        field.typeText("请用 shell 工具执行 sleep 40，然后只回复 slept-\(stamp)。")
        app.buttons["sendButton"].tap()

        // 1) 运行中：停止键出现（和发送键同一个位置），并显示运行指示 + 计时
        let stop = app.buttons["stopButton"]
        XCTAssertTrue(stop.waitForExistence(timeout: 90), "运行中应出现停止键")
        let indicator = app.descendants(matching: .any)["runIndicator"].firstMatch
        XCTAssertTrue(indicator.waitForExistence(timeout: 10), "应显示运行指示")
        sleep(3)
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "running-with-stop"; a.lifetime = .keepAlways; add(a)

        // 2) 点停止：界面立刻进入“已停止”，停止键换回发送键
        stop.tap()
        XCTAssertTrue(app.staticTexts["已停止"].waitForExistence(timeout: 3), "点击后应立即显示已停止")
        let b = XCTAttachment(screenshot: app.screenshot()); b.name = "stopped"; b.lifetime = .keepAlways; add(b)

        // 3) 之后不应收到 slept-<stamp>
        sleep(45)
        XCTAssertFalse(app.staticTexts["slept-\(stamp)"].exists, "任务应已被真正停止，不应再有回复")
    }
}
