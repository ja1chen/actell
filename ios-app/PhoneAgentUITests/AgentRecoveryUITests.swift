import XCTest

@MainActor final class AgentRecoveryUITests: XCTestCase {
    func testRecoverReadableHistoryCreatesNewConversationAndRetainsOriginal() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-test-history-corrupt", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let row = app.staticTexts["Recovery fixture"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
        row.tap()
        XCTAssertTrue(app.staticTexts["Verified answer"].waitForExistence(timeout: 5))
        let recover = app.buttons["recoverConversationHistory"]
        XCTAssertTrue(recover.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["stopRun"].exists)
        recover.tap()
        let leftDamagedSession = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: recover)
        wait(for: [leftDamagedSession], timeout: 10)
        XCTAssertTrue(app.staticTexts["Verified answer"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["stopRun"].exists, "Recovering history must not start a task")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        // The original and recovered conversations retain the same title.
        let rows = app.staticTexts.matching(identifier: "Recovery fixture")
        XCTAssertTrue(rows.element(boundBy: 1).waitForExistence(timeout: 5), app.debugDescription)
        rows.element(boundBy: 0).tap()
        if !app.buttons["recoverConversationHistory"].waitForExistence(timeout: 2) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            rows.element(boundBy: 1).tap()
        }
        XCTAssertTrue(app.buttons["recoverConversationHistory"].waitForExistence(timeout: 5), "The original damaged session remains accessible")
        XCTAssertTrue(app.staticTexts["Verified answer"].exists)
        XCTAssertFalse(app.buttons["stopRun"].exists)
    }
}
