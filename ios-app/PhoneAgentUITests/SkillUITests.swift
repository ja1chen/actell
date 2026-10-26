import XCTest

@MainActor final class SkillUITests: XCTestCase {
    func testNativeImportInspectToggleConfirmDeleteAndRealSkillToolCard() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-test-skill-tools", "--ui-test-light"]
        app.launch(); app.buttons["设置"].tap()
        app.buttons["manageSkills"].tap()
        importSkill(app)
        let title = app.staticTexts["Synthetic Guide"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 8), app.debugDescription)
        title.tap()
        XCTAssertTrue(app.scrollViews["skillDocument"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "SYNTHETIC_SKILL_BODY")).firstMatch.exists)
        app.navigationBars["Synthetic Guide"].buttons.firstMatch.tap()
        let toggle = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH %@", "enableSkill-")).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); toggle.tap(); XCTAssertEqual(toggle.value as? String, "0")
        toggle.tap(); XCTAssertEqual(toggle.value as? String, "1")
        importSkill(app)
        XCTAssertEqual(app.switches.matching(NSPredicate(format: "identifier BEGINSWITH %@", "enableSkill-")).count, 1)
        capture("skill-management-imported")
        let remove = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "deleteSkill-")).firstMatch
        remove.tap(); app.alerts.buttons["取消"].tap(); XCTAssertTrue(title.exists)
        remove.tap(); app.alerts.buttons["删除"].tap()
        XCTAssertTrue(app.staticTexts["暂无本地技能"].waitForExistence(timeout: 5))
        importSkill(app); XCTAssertTrue(title.waitForExistence(timeout: 8))
        app.navigationBars["技能"].buttons.firstMatch.tap(); app.buttons["关闭"].tap()
        app.staticTexts["新会话"].tap()
        let input = app.textViews["messageInput"]
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5)); input.typeText("Use synthetic guide")
        app.buttons["sendMessage"].tap()
        XCTAssertTrue(app.staticTexts["合成技能已读取。"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ 次工具调用")).firstMatch.tap()
        XCTAssertTrue(app.otherElements["tool-invocation-succeeded-load_skill"].exists)
        XCTAssertTrue(app.staticTexts["技能 · Synthetic Guide"].exists)
        capture("skill-tool-name-and-icon")
    }
    private func importSkill(_ app: XCUIApplication) {
        app.buttons["importSkill"].tap()
        let file = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", "SKILL")).firstMatch
        if !file.waitForExistence(timeout: 2) {
            let browse = app.buttons.matching(NSPredicate(format: "label IN %@", ["Browse", "浏览"])).firstMatch
            if browse.waitForExistence(timeout: 2) { browse.tap() }
            let local = app.staticTexts.matching(NSPredicate(format: "label IN %@", ["On My iPhone", "我的 iPhone", "我的iPhone"])).firstMatch
            if local.waitForExistence(timeout: 2) { local.tap() }
            let folder = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "ProjectTodosFixtures")).firstMatch
            XCTAssertTrue(folder.waitForExistence(timeout: 5), app.debugDescription); folder.tap()
        }
        XCTAssertTrue(file.waitForExistence(timeout: 5), app.debugDescription); file.tap()
        let open = app.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "打开"])).firstMatch
        if open.waitForExistence(timeout: 1) { open.tap() }
    }
    private func capture(_ name: String) {
        let item = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        item.name = name; item.lifetime = .keepAlways; add(item)
    }
}
