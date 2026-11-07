import XCTest

@MainActor final class ReasoningUITests: XCTestCase {
    private func disclosure(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "思考", "1 段思考")).firstMatch
    }
    private func expandCompletedThought(_ app: XCUIApplication) {
        app.buttons["1 段思考"].tap()
        XCTAssertFalse(content(app).exists)
        let thought = app.buttons["思考"]
        XCTAssertTrue(thought.waitForExistence(timeout: 5))
        XCTAssertEqual(thought.value as? String, "已收起")
        thought.tap()
    }
    private func content(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "reasoningContent-")).firstMatch
    }
    private func start(_ outcome: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-test-reasoning-seed", "--ui-test-reasoning-" + outcome, "--ui-test-light"]
        app.launch(); app.staticTexts["新建会话"].tap()
        let input = app.textViews["messageInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); input.typeText("Synthetic reasoning")
        app.buttons["sendMessage"].tap()
        XCTAssertTrue(disclosure(app).waitForExistence(timeout: 5))
        return app
    }
    func testStreamingCollapseCancelAndDarkHistoryRestore() {
        let app = start("paused")
        XCTAssertFalse(app.staticTexts["接收中"].exists)
        XCTAssertFalse(content(app).exists)
        disclosure(app).tap()
        XCTAssertTrue(content(app).waitForExistence(timeout: 5))
        XCTAssertTrue(content(app).label.contains("合成思考第二段"))
        capture("reasoning-streaming")
        app.buttons["stopRun"].tap()
        let stopped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["stopRun"])
        XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["1 段思考"].waitForExistence(timeout: 5))
        XCTAssertFalse(content(app).exists)
        app.terminate()
        app.launchArguments = ["--ui-testing", "--ui-test-reasoning-restore", "--ui-test-dark"]
        app.launch(); app.staticTexts["Synthetic reasoning"].firstMatch.tap()
        XCTAssertTrue(disclosure(app).waitForExistence(timeout: 5)); XCTAssertFalse(content(app).exists)
        expandCompletedThought(app); XCTAssertTrue(content(app).waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(content(app).label.contains("合成思考第二段"))
        XCTAssertFalse(app.staticTexts["已中断"].exists)
        capture("reasoning-interrupted-restored-dark")
    }
    func testCompletedThoughtIsSeparateFromAnswerAndCanCollapse() {
        let app = start("completed")
        XCTAssertTrue(app.staticTexts["合成答复。"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["已完成"].exists); XCTAssertFalse(content(app).exists)
        expandCompletedThought(app); XCTAssertTrue(content(app).waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.staticTexts["服务商返回的思考内容或摘要"].exists)
        capture("reasoning-completed")
        app.buttons["思考"].tap(); XCTAssertFalse(content(app).exists)
    }
    func testFailedThoughtRetainsReadablePartialContent() {
        let app = start("failed")
        let stopped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["stopRun"])
        XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 5), .completed)
        expandCompletedThought(app); XCTAssertTrue(content(app).waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(content(app).label.contains("合成思考第一段"))
        XCTAssertFalse(app.staticTexts["合成答复。"].exists)
        capture("reasoning-failed")
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
