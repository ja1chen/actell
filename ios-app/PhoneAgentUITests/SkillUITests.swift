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
        let version = app.staticTexts["v1"].firstMatch
        XCTAssertTrue(version.exists)
        XCTAssertLessThan(abs(title.frame.midY - version.frame.midY), title.frame.height)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "deleteSkill-")).firstMatch.exists)
        capture("skill-list-name-and-version")
        XCTAssertEqual(app.switches.count, 0)
        let row = app.cells.containing(.staticText, identifier: "Synthetic Guide").firstMatch
        XCTAssertFalse(row.staticTexts["（未启用）"].exists)
        title.tap()
        XCTAssertTrue(app.scrollViews["skillDocument"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "SYNTHETIC_SKILL_BODY")).firstMatch.exists)
        let toggle = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH %@", "enableSkill-")).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let control = toggle.switches.firstMatch
        XCTAssertTrue(control.exists)
        control.tap(); XCTAssertEqual(toggle.value as? String, "0")
        capture("skill-detail-disabled")
        app.navigationBars["Synthetic Guide"].buttons.firstMatch.tap()
        XCTAssertTrue(row.staticTexts["（未启用）"].waitForExistence(timeout: 3))
        XCTAssertLessThan(abs(row.staticTexts["（未启用）"].frame.midY - version.frame.midY), title.frame.height)
        XCTAssertGreaterThan(row.staticTexts["（未启用）"].frame.minX, version.frame.maxX)
        capture("skill-list-disabled")
        XCTAssertEqual(app.switches.count, 0)
        title.tap()
        control.tap(); XCTAssertEqual(toggle.value as? String, "1")
        app.navigationBars["Synthetic Guide"].buttons.firstMatch.tap()
        XCTAssertFalse(row.staticTexts["（未启用）"].exists)
        importSkill(app)
        XCTAssertEqual(app.staticTexts.matching(identifier: "Synthetic Guide").count, 1)
        XCTAssertEqual(app.switches.count, 0)
        capture("skill-management-imported")
        let remove = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "deleteSkill-")).firstMatch
        row.swipeLeft()
        XCTAssertTrue(remove.waitForExistence(timeout: 3))
        remove.tap(); app.alerts.buttons["取消"].tap(); XCTAssertTrue(title.exists)
        row.swipeLeft()
        XCTAssertTrue(remove.waitForExistence(timeout: 3))
        remove.tap(); app.alerts.buttons["删除"].tap()
        XCTAssertTrue(app.staticTexts["暂无用户技能"].waitForExistence(timeout: 5))
        importSkill(app); XCTAssertTrue(title.waitForExistence(timeout: 8))
        app.navigationBars["技能"].buttons.firstMatch.tap(); app.buttons["关闭"].tap()
        app.staticTexts["新建会话"].tap()
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
            let browse = app.tabBars["DOC.browsingModeTabBar"].buttons.matching(NSPredicate(format: "label IN %@", ["Browse", "浏览"])).firstMatch
            XCTAssertTrue(browse.waitForExistence(timeout: 10), app.debugDescription)
            browse.tap()
            let local = app.staticTexts.matching(NSPredicate(format: "label IN %@", ["On My iPhone", "我的 iPhone", "我的iPhone"])).firstMatch
            if local.waitForExistence(timeout: 2) { local.tap() }
            let folder = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "ProjectTodosFixtures")).firstMatch
            XCTAssertTrue(folder.waitForExistence(timeout: 5), app.debugDescription); folder.tap()
        }
        XCTAssertTrue(file.waitForExistence(timeout: 5), app.debugDescription); file.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: app.buttons["importSkill"])
        if XCTWaiter.wait(for: [dismissed], timeout: 3) == .completed { return }
        let open = app.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "打开"])).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 3), app.debugDescription)
        open.tap()
    }
    private func capture(_ name: String) {
        let item = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        item.name = name; item.lifetime = .keepAlways; add(item)
    }
}
