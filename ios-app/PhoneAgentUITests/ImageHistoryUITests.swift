import XCTest

@MainActor final class ImageHistoryUITests: XCTestCase {
    func testSyntheticScreenshotRemainsViewableAfterAppRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-test-images-seed", "--ui-test-light"]
        app.launch(); app.staticTexts["新建会话"].tap()
        let input = app.textViews["messageInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap(); input.typeText("Synthetic image history")
        app.buttons["sendMessage"].tap()
        XCTAssertTrue(app.buttons["approveTool"].waitForExistence(timeout: 10))
        app.buttons["stopRun"].tap()
        app.terminate()
        app.launchArguments = ["--ui-testing", "--ui-test-images-restore", "--ui-test-dark"]
        app.launch(); app.staticTexts["Synthetic image history"].firstMatch.tap()
        app.buttons.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ 次工具调用")).firstMatch.tap()
        let preview = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "查看屏幕")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5)); preview.tap()
        XCTAssertFalse(app.staticTexts["请求参数"].exists)
        XCTAssertFalse(app.staticTexts["查看本地截图"].exists)
        let thumbnail = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "attachment-")).firstMatch
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 5)); thumbnail.tap()
        XCTAssertTrue(app.images["本地原图"].waitForExistence(timeout: 5))
        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        capture.name = "local-original-after-relaunch"; capture.lifetime = .keepAlways; add(capture)
        app.buttons["完成"].tap()
        XCTAssertFalse(app.buttons["approveTool"].exists)
    }
}
