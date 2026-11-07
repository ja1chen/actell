import XCTest

@MainActor final class AttachmentPickerUITests: XCTestCase {
    func testNativePickersCanCancelWithoutSending() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-test-demo-history", "--ui-test-light"]
        app.launch(); app.staticTexts["新建会话"].tap()
        for title in ["添加照片", "添加文件"] {
            let plus = app.buttons["addAttachment"]
            plus.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let item = app.descendants(matching: .any)[title].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription); item.tap()
            let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消", "Close", "关闭"])).firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 8), app.debugDescription)
            capture(title + "-native-picker")
            cancel.tap()
            XCTAssertTrue(app.descendants(matching: .any)["addAttachment"].firstMatch.waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["stopRun"].exists)
            XCTAssertFalse(app.scrollViews["draftAttachments"].exists)
        }
    }
    func testNativePhotoSelectionAndRepeatedSelectionStayInDraft() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-test-demo-history", "--ui-test-light"]
        app.launch(); app.staticTexts["新建会话"].tap()
        for _ in 0..<2 {
            app.buttons["addAttachment"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let photo = app.descendants(matching: .any)["添加照片"].firstMatch
            XCTAssertTrue(photo.waitForExistence(timeout: 5)); photo.tap()
            // prepare_ui_fixtures.py adds this run's synthetic PNG as the newest photo.
            let image = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
            XCTAssertTrue(image.waitForExistence(timeout: 8), app.debugDescription)
            image.tap()
            let add = app.buttons.matching(NSPredicate(format: "label IN %@", ["Add", "添加", "Done", "完成"])).firstMatch
            XCTAssertTrue(add.waitForExistence(timeout: 5), app.debugDescription); add.tap()
            let draft = app.scrollViews["draftAttachments"]
            XCTAssertTrue(draft.waitForExistence(timeout: 8), app.debugDescription)
            XCTAssertEqual(draft.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "removeAttachment-")).count, 1)
            XCTAssertFalse(app.buttons["stopRun"].exists)
        }
        capture("native-photo-imported")
        app.buttons["sendMessage"].tap()
        XCTAssertTrue(app.buttons["approveTool"].waitForExistence(timeout: 10))
        app.buttons["stopRun"].tap()
    }
    func testNativeFileSelectionImportsAndSendsText() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-test-demo-history", "--ui-test-dark"]
        app.launch(); app.staticTexts["新建会话"].tap()
        app.buttons["addAttachment"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let file = app.descendants(matching: .any)["添加文件"].firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 5)); file.tap()
        let note = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "synthetic-note")).firstMatch
        if !note.waitForExistence(timeout: 1) {
            let browse = app.buttons.matching(NSPredicate(format: "label IN %@", ["Browse", "浏览"])).firstMatch
            if browse.waitForExistence(timeout: 3) { browse.tap() }
            let local = app.staticTexts.matching(NSPredicate(format: "label IN %@", ["On My iPhone", "我的 iPhone", "我的iPhone"])).firstMatch
            if local.waitForExistence(timeout: 3) { local.tap() }
            let folder = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "ProjectTodosFixtures")).firstMatch
            XCTAssertTrue(folder.waitForExistence(timeout: 5), app.debugDescription); folder.tap()
        }
        XCTAssertTrue(note.waitForExistence(timeout: 5), app.debugDescription); note.tap()
        let open = app.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "打开", "Done", "完成"])).firstMatch
        if open.waitForExistence(timeout: 2) { open.tap() }
        XCTAssertTrue(app.scrollViews["draftAttachments"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertFalse(app.buttons["stopRun"].exists)
        app.scrollViews["draftAttachments"].buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "attachment-")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["SYNTHETIC_NATIVE_FILE_CONTENT\nNo user data."].waitForExistence(timeout: 5))
        app.buttons["完成"].tap(); app.buttons["sendMessage"].tap()
        XCTAssertTrue(app.buttons["approveTool"].waitForExistence(timeout: 10)); app.buttons["stopRun"].tap()
    }
    func testSyntheticDraftPreviewRemovalAndExplicitSend() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-test-attachments", "--ui-test-dark"]
        app.launch(); app.staticTexts["新建会话"].tap()
        let draft = app.scrollViews["draftAttachments"]
        XCTAssertTrue(draft.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["stopRun"].exists)
        capture("attachment-draft-dark")
        let preview = draft.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "attachment-")).firstMatch
        preview.tap(); XCTAssertTrue(app.images["本地原图"].waitForExistence(timeout: 5)); app.buttons["完成"].tap()
        draft.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "removeAttachment-")).firstMatch.tap()
        XCTAssertEqual(draft.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "removeAttachment-")).count, 1)
        app.buttons["sendMessage"].tap()
        XCTAssertTrue(app.buttons["approveTool"].waitForExistence(timeout: 10))
        XCTAssertFalse(draft.exists)
        capture("attachment-sent-in-history")
        app.buttons["stopRun"].tap()
    }
    private func capture(_ name: String) {
        let item = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        item.name = name; item.lifetime = .keepAlways; add(item)
    }
}
