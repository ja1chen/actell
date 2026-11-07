import XCTest

@MainActor final class ComposerUITests: XCTestCase {
    func testLightComposerKeyboardAndApproval() { verifyAppearance("light") }
    func testDarkComposerKeyboardAndApproval() { verifyAppearance("dark") }
    private func verifyAppearance(_ appearance: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-test-demo-history", "--ui-test-" + appearance]
        app.launch(); app.staticTexts["新建会话"].tap()
        let input = app.textViews["messageInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap(); input.typeText("Synthetic tap")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(input.frame.maxY, app.keyboards.firstMatch.frame.minY + 2)
        capture(appearance + "-composer-keyboard")
        app.buttons["sendMessage"].tap()
        let approve = app.buttons["approveTool"]
        XCTAssertTrue(approve.waitForExistence(timeout: 10)); XCTAssertTrue(approve.isHittable)
        XCTAssertLessThan(approve.frame.maxY, input.frame.minY)
        capture(appearance + "-approval")
        app.buttons["approvalDetailsToggle"].tap()
        XCTAssertTrue(app.scrollViews["approvalDetails"].exists)
        capture(appearance + "-approval-details")
        app.scrollViews["conversationMessages"].swipeUp()
        XCTAssertTrue(app.buttons["rejectTool"].isHittable)
        app.buttons["stopRun"].tap()
        XCTAssertFalse(approve.exists)
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
