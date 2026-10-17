import XCTest

@MainActor final class ConversationUITests: XCTestCase {
    func testCompletedTurnSummariesCountCollapseAndKeepAnswerVisible() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-test-turn-summaries"]
        app.launch(); app.staticTexts["汇总验收"].firstMatch.tap()
        let summary = app.buttons["2 次工具调用 · 2 段思考"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(summary.value as? String, "已收起")
        XCTAssertTrue(app.staticTexts["汇总后的最终答复"].exists)
        XCTAssertTrue(app.staticTexts["没有工具和思考的答复"].exists)
        XCTAssertFalse(app.buttons["0 次工具调用"].exists)
        XCTAssertFalse(app.buttons["0 段思考"].exists)
        XCTAssertFalse(app.staticTexts["第1段思考内容"].exists)
        summary.tap()
        let tools = app.otherElements.matching(identifier: "tool-invocation-succeeded-wait")
        XCTAssertEqual(tools.count, 2)
        let firstThought = app.staticTexts["第1段思考内容"], secondThought = app.staticTexts["第2段思考内容"]
        XCTAssertFalse(firstThought.exists); XCTAssertFalse(secondThought.exists)
        let thoughtHeaders = app.buttons.matching(NSPredicate(format: "label == %@", "思考"))
        XCTAssertEqual(thoughtHeaders.count, 2)
        XCTAssertEqual(thoughtHeaders.element(boundBy: 0).value as? String, "已收起")
        XCTAssertEqual(thoughtHeaders.element(boundBy: 1).value as? String, "已收起")
        thoughtHeaders.element(boundBy: 0).tap()
        XCTAssertTrue(firstThought.exists); XCTAssertFalse(secondThought.exists)
        thoughtHeaders.element(boundBy: 1).tap()
        XCTAssertTrue(secondThought.exists)
        XCTAssertLessThan(firstThought.frame.minY, app.staticTexts["中间答复1"].frame.minY)
        XCTAssertLessThan(app.staticTexts["中间答复1"].frame.minY, tools.element(boundBy: 0).frame.minY)
        XCTAssertLessThan(tools.element(boundBy: 0).frame.minY, secondThought.frame.minY)
        XCTAssertLessThan(secondThought.frame.minY, tools.element(boundBy: 1).frame.minY)
        capture("turn-summary-expanded-in-message-order")
        summary.tap()
        XCTAssertFalse(firstThought.exists)
        XCTAssertFalse(tools.firstMatch.exists)
        capture("turn-summary-collapsed")
        summary.tap()
        XCTAssertFalse(firstThought.exists); XCTAssertFalse(secondThought.exists)
        XCTAssertEqual(thoughtHeaders.element(boundBy: 0).value as? String, "已收起")
    }
    func testUnsentNewConversationStaysOutOfHistoryUntilFirstSend() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-test-new-conversation"]
        app.launch()
        let newConversation = app.buttons["newConversation"]
        XCTAssertTrue(newConversation.waitForExistence(timeout: 5))
        newConversation.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(newConversation.waitForExistence(timeout: 5))
        newConversation.tap()
        let input = app.textViews["messageInput"]
        input.tap(); input.tap(); input.typeText("未发送草稿")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(newConversation.waitForExistence(timeout: 5))
        newConversation.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertFalse((input.value as? String ?? "").contains("未发送草稿"))
        input.tap(); input.tap(); input.typeText("保存第一条消息")
        app.buttons["sendMessage"].tap()
        XCTAssertTrue(app.staticTexts["合成答复。"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertFalse(newConversation.exists)
        XCTAssertTrue(app.staticTexts["保存第一条消息"].waitForExistence(timeout: 5))
        capture("first-message-creates-history")
    }
    func testBackgroundCompletionRefreshesOpenConversationWithoutReentry() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-test-background-completion"]
        app.launch()
        app.staticTexts["后台完成刷新验收"].tap()
        XCTAssertTrue(app.staticTexts["等待后台完成"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        app.activate()
        XCTAssertTrue(app.staticTexts["后台任务最终回复"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["后台任务最终回复"].isHittable, app.debugDescription)
        XCTAssertTrue(app.textViews["messageInput"].exists)
        capture("background-completion-direct-return")
    }
    func testBackgroundCompletionRoutesFromHistoryOnlyWhenForegroundReturns() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-test-background-completion", "--ui-test-background-auto-route"]
        app.launch()
        XCTAssertTrue(app.staticTexts["后台完成刷新验收"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        app.activate()
        let reply = app.staticTexts["后台任务最终回复"]
        XCTAssertTrue(reply.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(reply.isHittable, app.debugDescription)
        XCTAssertTrue(app.textViews["messageInput"].exists)
        capture("background-completion-auto-route")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        app.activate()
        XCTAssertTrue(app.navigationBars["会话"].waitForExistence(timeout: 5), "Consumed completion must not route again")
    }
    func testBackgroundCompletionKeepsMessagesVisibleAfterLongTurnCollapses() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-test-background-completion"]
        app.launch()
        app.staticTexts["后台完成刷新验收"].tap()
        XCTAssertTrue(app.staticTexts["等待后台完成"].waitForExistence(timeout: 5))
        let messages = app.scrollViews["conversationMessages"]
        messages.swipeDown(); messages.swipeDown()
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        app.activate()
        XCTAssertTrue(app.staticTexts["后台任务最终回复"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["后台任务最终回复"].isHittable, app.debugDescription)
        capture("background-completion-history-position")
        for second in 1...10 {
            Thread.sleep(forTimeInterval: 1)
            XCTAssertTrue(app.staticTexts["后台任务最终回复"].exists, "Reply disappeared at second \(second): " + app.debugDescription)
            XCTAssertTrue(app.staticTexts["后台任务最终回复"].isHittable, "Reply moved out of viewport at second \(second): " + app.debugDescription)
        }
        capture("background-completion-history-position-stable")
    }
    func testReplyRemainsVisibleWhenCompletionFoldsAfterForegroundReturn() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-test-background-completion", "--ui-test-background-delayed-finish", "--ui-test-background-auto-route"]
        app.launch()
        app.staticTexts["后台完成刷新验收"].tap()
        XCTAssertTrue(app.staticTexts["等待后台完成"].waitForExistence(timeout: 5))
        let messages = app.scrollViews["conversationMessages"]
        messages.swipeDown(); messages.swipeDown()
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        app.activate()
        let reply = app.staticTexts["后台任务最终回复"]
        XCTAssertTrue(reply.waitForExistence(timeout: 5), app.debugDescription)
        capture("foreground-before-delayed-fold")
        for second in 1...10 {
            Thread.sleep(forTimeInterval: 1)
            XCTAssertTrue(reply.exists, "Reply disappeared at second \(second): " + app.debugDescription)
            let frame = app.staticTexts["后台任务最终回复"].frame
            let top = app.navigationBars.firstMatch.frame.maxY
            let bottom = app.textViews["messageInput"].frame.minY
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThan(frame.height, 0)
            XCTAssertGreaterThan(frame.maxY, top, "Reply moved above viewport at second \(second)")
            XCTAssertLessThan(frame.minY, bottom, "Reply moved below viewport at second \(second)")
            if [1, 3, 10].contains(second) { capture("foreground-delayed-fold-second-\(second)") }
        }
        XCTAssertTrue(app.buttons["30 次工具调用 · 30 段思考"].exists, "Must reach the folded completed layout")
        capture("foreground-after-delayed-fold-stable")
    }
    private func launch(demo: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-deviceControlRoute", "ncmDeveloper"] + (demo ? ["--ui-test-demo-history"] : [])
        app.launch()
        return app
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testExpandingLongReasoningAndToolKeepsDisclosureInPlace() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-test-disclosure-scroll"]
        app.launch()
        app.staticTexts["新会话"].firstMatch.tap()
        XCTAssertTrue(app.scrollViews["conversationMessages"].waitForExistence(timeout: 5))
        for title in ["1 次工具调用 · 1 段思考"] {
            let toggle = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            for _ in 0..<3 {
                XCTAssertTrue(toggle.isHittable)
                let before = toggle.frame.minY
                toggle.tap()
                // Wait through layout/animation; a bottom jump hides the header
                // above the viewport when the expanded body spans many screens.
                let jumped = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    !toggle.isHittable || abs(toggle.frame.minY - before) >= 12
                }, object: app)
                jumped.isInverted = true
                XCTAssertEqual(XCTWaiter.wait(for: [jumped], timeout: 1.5), .completed)
                XCTAssertTrue(toggle.isHittable)
                toggle.tap()
            }
        }
        capture("disclosure-reading-position")
    }
    func testLongToolResultScrollsInsideBoundedCardToItsEnd() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-test-disclosure-scroll"]
        app.launch(); app.staticTexts["新会话"].firstMatch.tap()
        app.buttons["1 次工具调用 · 1 段思考"].tap()
        app.scrollViews["conversationMessages"].swipeUp()
        let toggle = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "查询 App")).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); toggle.tap()
        let card = app.scrollViews["toolResultScroll"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(card.frame.height, 321)
        app.scrollViews["conversationMessages"].swipeUp()
        let headerY = toggle.frame.minY
        let tail = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", "工具结果末尾标记")).firstMatch
        for _ in 0..<15 {
            let last = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            last.press(forDuration: 0.05, thenDragTo: card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
        }
        XCTAssertTrue(tail.exists)
        XCTAssertEqual(card.value as? String, "已到末尾")
        XCTAssertTrue(toggle.isHittable)
        XCTAssertEqual(toggle.frame.minY, headerY, accuracy: 12)
        capture("tool-result-internal-scroll")
    }
    func testReasoningHeaderWhitespaceAndArrowCollapseWithOneTap() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-test-disclosure-scroll"]
        app.launch(); app.staticTexts["新会话"].firstMatch.tap()
        app.buttons["1 次工具调用 · 1 段思考"].tap()
        let header = app.buttons["思考"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        let content = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "reasoningContent-")).firstMatch
        for x in [0.5, 0.95, 0.5, 0.95, 0.5, 0.95] {
            // Tap the empty middle and the chevron, rather than only the text.
            header.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.5)).tap()
            XCTAssertTrue(content.waitForExistence(timeout: 2))
            header.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.5)).tap()
            let collapsed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: content)
            XCTAssertEqual(XCTWaiter.wait(for: [collapsed], timeout: 2), .completed)
        }
        capture("reasoning-single-tap-collapse")
    }
    func testConversationEntryAndRepeatedActivityLinksScrollToLatest() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-test-composer-history", "--ui-test-conversation-navigation"]
        app.launch(); app.staticTexts["新会话"].firstMatch.tap()
        let scroll = app.scrollViews["conversationMessages"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        let route = try XCTUnwrap(URL(string: try XCTUnwrap(scroll.value as? String)))
        let tail = app.staticTexts["滚动验收最后一条消息"]
        func assertAtBottom() {
            capture("conversation-navigation-position")
            let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in tail.isHittable }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed)
        }
        assertAtBottom()
        for _ in 0..<2 {
            scroll.swipeDown(); scroll.swipeDown()
            XCTAssertFalse(tail.isHittable, "History remains freely scrollable")
            XCUIDevice.shared.system.open(route)
            assertAtBottom()
        }
        scroll.swipeDown(); scroll.swipeDown()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.staticTexts["新会话"].firstMatch.tap()
        assertAtBottom()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCUIDevice.shared.press(.home)
        XCUIDevice.shared.system.open(route)
        assertAtBottom()
        capture("conversation-entry-at-latest")
    }
    private func backgroundToggle(_ name: String, in app: XCUIApplication) -> XCUIElement {
        let element = app.switches[name == "resident" ? "backgroundResidentEnabled" : "backgroundMechanism." + name]
        for _ in 0..<6 where !element.isHittable {
            if element.exists && element.frame.minY < app.frame.midY { app.swipeDown() }
            else { app.swipeUp() }
        }
        XCTAssertTrue(element.isHittable, app.debugDescription)
        return element
    }

    func testBackgroundResidentSettingPersistsWithoutCreatingConversation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-test-live-activity"]
        app.launch()
        app.buttons["设置"].tap(); app.buttons["openBackgroundSettings"].tap()
        let resident = app.switches["backgroundResidentEnabled"]
        for _ in 0..<5 where !resident.isHittable { app.swipeUp() }
        XCTAssertTrue(resident.waitForExistence(timeout: 5), app.debugDescription)
        if resident.value as? String == "1" { resident.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        XCTAssertEqual(resident.value as? String, "0")
        resident.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(resident.value as? String, "1")
        capture("settings-background-resident-enabled")
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 5))
        // Let the Home transition finish before collecting system presentation evidence.
        Thread.sleep(forTimeInterval: 2)
        capture("background-resident-standby-island")
        app.activate()
        XCTAssertTrue(resident.waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        app.buttons["设置"].tap(); app.buttons["openBackgroundSettings"].tap()
        _ = backgroundToggle("resident", in: app)
        XCTAssertTrue(resident.waitForExistence(timeout: 5))
        XCTAssertEqual(resident.value as? String, "1")
        resident.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(resident.value as? String, "0")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["关闭"].tap()
        XCTAssertFalse(app.staticTexts["Siri · 待确认"].exists)
        XCTAssertFalse(app.buttons["stopRun"].exists)
    }
    func testBackgroundSelectionAllowsMultipleAndEmptyAndPersists() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--background-fixture-reset"]
        app.launch(); app.buttons["设置"].tap(); app.buttons["openBackgroundSettings"].tap()
        let names = ["audio", "pictureInPicture", "systemTask", "location"]
        func toggle(_ name: String) -> XCUIElement { backgroundToggle(name, in: app) }
        XCTAssertEqual(toggle("audio").value as? String, "1")
        XCTAssertEqual(toggle("pictureInPicture").value as? String, "0")
        XCTAssertEqual(toggle("systemTask").value as? String, "0")
        XCTAssertEqual(toggle("location").value as? String, "0")
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
        XCTAssertFalse(app.buttons["enableBackgroundLocation"].exists)
        XCTAssertFalse(app.buttons["重试已选持续方式"].exists)
        capture("background-settings-default-no-permission")
        toggle("location").coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        toggle("pictureInPicture").coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        toggle("systemTask").coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        for name in names { XCTAssertEqual(toggle(name).value as? String, "1") }
        for name in names { toggle(name).coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        capture("background-explicit-empty")
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch(); app.buttons["设置"].tap(); app.buttons["openBackgroundSettings"].tap()
        for name in names { XCTAssertEqual(toggle(name).value as? String, "0") }
        XCTAssertFalse(app.buttons["stopRun"].exists)
    }
    func testPiPSelectionReturnsFromBackgroundAndCanLeaveSettingsSafely() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--background-fixture-reset"]
        app.launch(); app.buttons["设置"].tap(); app.buttons["openBackgroundSettings"].tap()
        let pip = backgroundToggle("pictureInPicture", in: app)
        pip.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(pip.value as? String, "1")
        let resident = backgroundToggle("resident", in: app)
        resident.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.navigationBars["后台执行"].waitForExistence(timeout: 5))
        XCTAssertEqual(backgroundToggle("pictureInPicture", in: app).value as? String, "1")
        capture("pip-selection-returned-to-app")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        app.buttons["关闭"].tap()
        XCTAssertTrue(app.buttons["设置"].waitForExistence(timeout: 5))
        app.buttons["设置"].tap(); app.buttons["openBackgroundSettings"].tap()
        let restored = backgroundToggle("pictureInPicture", in: app)
        restored.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        backgroundToggle("resident", in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    }

    func testLocationToggleRequestsNativePermissionWithoutTaskOrResidency() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--background-fixture-reset", "--background-fixture-native-permission"]
        app.launch(); app.buttons["设置"].tap()
        XCTAssertFalse(app.switches["backgroundMechanism.location"].exists)
        app.buttons["openBackgroundSettings"].tap()
        XCTAssertTrue(app.navigationBars["后台执行"].waitForExistence(timeout: 5))
        let location = backgroundToggle("location", in: app)
        XCTAssertEqual(location.value as? String, "0")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        capture("background-settings-location-off")
        location.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let prompt = app.alerts.firstMatch.waitForExistence(timeout: 3) ? app.alerts.firstMatch : system.alerts.firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 5), app.debugDescription)
        capture("background-settings-native-location-permission")
        let deny = prompt.buttons.matching(NSPredicate(format: "label IN %@", ["不允许", "Don’t Allow", "Don't Allow"])).firstMatch
        XCTAssertTrue(deny.exists, prompt.debugDescription)
        deny.tap()
        XCTAssertTrue(app.staticTexts["backgroundLocationPermissionStatus"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["backgroundLocationPermissionStatus"].label.contains("未允许访问位置"))
        XCTAssertEqual(backgroundToggle("audio", in: app).value as? String, "1")
        XCTAssertEqual(backgroundToggle("resident", in: app).value as? String, "0")
        XCTAssertFalse(app.buttons["stopRun"].exists)
    }

    func testLocationDeniedKeepsAudioSelectedAndShowsPermissionHelp() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--background-fixture-reset", "--background-fixture-location-denied"]
        app.launch(); app.buttons["设置"].tap(); app.buttons["openBackgroundSettings"].tap()
        XCTAssertEqual(app.switches["backgroundMechanism.audio"].value as? String, "1")
        let location = backgroundToggle("location", in: app)
        XCTAssertEqual(location.value as? String, "0")
        location.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(location.value as? String, "1")
        XCTAssertTrue(app.staticTexts["backgroundLocationPermissionStatus"].label.contains("未允许访问位置"))
        XCTAssertTrue(app.descendants(matching: .any)["backgroundLocationSettings"].exists, app.debugDescription)
        let resident = app.switches["backgroundResidentEnabled"]
        for _ in 0..<5 where !resident.isHittable { app.swipeUp() }
        resident.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(backgroundToggle("audio", in: app).value as? String, "1")
        _ = backgroundToggle("location", in: app)
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
        capture("background-location-denied-independent-audio")
        _ = backgroundToggle("resident", in: app)
        resident.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    }
    func testLegacySystemSelectionAndResidentExplanation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--background-fixture-reset", "--background-fixture-legacy-system"]
        app.launch(); app.buttons["设置"].tap(); app.buttons["openBackgroundSettings"].tap()
        XCTAssertEqual(app.switches["backgroundMechanism.audio"].value as? String, "0")
        XCTAssertEqual(app.switches["backgroundMechanism.systemTask"].value as? String, "1")
        XCTAssertEqual(backgroundToggle("location", in: app).value as? String, "0")
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["backgroundNoIdleSource"].exists)
        capture("background-resident-system-only")
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
    }
    func testDeviceControlsAndSettingsDoNotStartAnything() {
        let app = launch()
        XCTAssertFalse(app.buttons["openProviders"].exists)
        XCTAssertFalse(app.buttons["deviceControls"].exists)
        app.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["openProviders"].exists)
        XCTAssertTrue(app.buttons["esp32ControlSettings"].exists)
        let title = app.navigationBars["设置"].staticTexts["设置"]
        XCTAssertLessThan(title.frame.height, 30)
        let titleY = title.frame.minY
        app.swipeUp()
        XCTAssertEqual(title.frame.minY, titleY, accuracy: 1)
        capture("settings-scrolled-fixed-title")
        app.swipeDown()
        XCTAssertEqual(title.frame.minY, titleY, accuracy: 1)
        capture("settings")
        app.buttons["esp32ControlSettings"].tap()
        XCTAssertTrue(app.navigationBars["ESP32 控制"].waitForExistence(timeout: 5))
        XCTAssertLessThan(app.navigationBars["ESP32 控制"].staticTexts["ESP32 控制"].frame.height, 30)
        XCTAssertFalse(app.buttons["startScreenCapture"].exists)
        capture("device-panel")
    }
    func testVPNLoopbackModePersistsAndShowsEditableAddresses() {
        let app = launch()
        app.buttons["设置"].tap()
        let mode = app.buttons["deviceControlMode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        capture("vpn-parent-settings")
        mode.tap()
        app.buttons["VPN 回环"].tap()
        app.buttons["esp32ControlSettings"].tap()
        XCTAssertTrue(app.navigationBars["VPN 回环控制"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "共用系统配对身份")).firstMatch.exists)
        XCTAssertEqual(app.textFields["vpnLoopbackInterfaceAddress"].value as? String, "10.7.1.1")
        XCTAssertEqual(app.textFields["vpnLoopbackPeerAddress"].value as? String, "10.7.0.1")
        XCTAssertTrue(app.buttons["配对"].exists)
        XCTAssertFalse(app.buttons["获取截图"].exists)
        let saveButton = app.navigationBars.buttons["saveVPNLoopbackConfiguration"]
        XCTAssertFalse(saveButton.exists)
        XCTAssertTrue(app.staticTexts["建立连接阶段需要处于 Wi-Fi 环境"].exists)
        func saveConfiguration() {
            XCTAssertEqual(app.navigationBars.buttons.matching(identifier: "saveVPNLoopbackConfiguration").count, 1)
            saveButton.tap()
            XCTAssertFalse(saveButton.exists)
        }
        capture("local-vpn-setup")
        let interfaceAddress = app.textFields["vpnLoopbackInterfaceAddress"]
        let presets = app.buttons["vpnLoopbackInterfaceAddressPresets"]
        for _ in 0..<3 {
            presets.tap()
            app.buttons["198.18.0.1"].tap()
            XCTAssertEqual(app.navigationBars.buttons.matching(identifier: "saveVPNLoopbackConfiguration").count, 1)
            presets.tap()
            app.buttons["10.7.1.1"].tap()
            XCTAssertFalse(saveButton.exists)
        }
        presets.tap()
        XCTAssertTrue(app.buttons["10.7.1.1"].exists)
        app.buttons["198.18.0.1"].tap()
        XCTAssertEqual(interfaceAddress.value as? String, "198.18.0.1")
        XCTAssertEqual(app.textFields["vpnLoopbackPeerAddress"].value as? String, "10.7.0.1")
        XCTAssertTrue(saveButton.exists)
        XCTAssertEqual(app.navigationBars.buttons.matching(identifier: "saveVPNLoopbackConfiguration").count, 1)
        capture("local-vpn-unsaved-preset")
        saveConfiguration()
        XCTAssertFalse(saveButton.exists)
        capture("local-vpn-preset")
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch()
        app.buttons["设置"].tap()
        app.buttons["esp32ControlSettings"].tap()
        XCTAssertTrue(app.navigationBars["VPN 回环控制"].waitForExistence(timeout: 5))
        XCTAssertEqual(interfaceAddress.value as? String, "198.18.0.1")
        presets.tap()
        app.buttons["vpnLoopbackInterfaceAddressCustom"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        interfaceAddress.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        interfaceAddress.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "198.18.0.1".count) + "10.9.1.1")
        XCTAssertEqual(interfaceAddress.value as? String, "10.9.1.1")
        saveConfiguration()
        app.terminate(); app.launch()
        app.buttons["设置"].tap()
        app.buttons["esp32ControlSettings"].tap()
        XCTAssertTrue(interfaceAddress.waitForExistence(timeout: 5))
        XCTAssertEqual(interfaceAddress.value as? String, "10.9.1.1")
        capture("local-vpn-custom-address")
        presets.tap()
        app.buttons["10.7.1.1"].tap()
        saveConfiguration()
        let peerAddress = app.textFields["vpnLoopbackPeerAddress"]
        let peerPresets = app.buttons["vpnLoopbackPeerAddressPresets"]
        peerPresets.tap()
        XCTAssertTrue(app.buttons["10.7.0.1"].exists)
        XCTAssertFalse(app.buttons["198.18.0.1"].exists)
        capture("local-vpn-peer-options")
        app.buttons["vpnLoopbackPeerAddressCustom"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        peerAddress.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        peerAddress.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "10.7.0.1".count) + "10.9.0.1")
        XCTAssertEqual(peerAddress.value as? String, "10.9.0.1")
        saveConfiguration()
        app.terminate(); app.launch()
        app.buttons["设置"].tap()
        app.buttons["esp32ControlSettings"].tap()
        XCTAssertTrue(peerAddress.waitForExistence(timeout: 5))
        XCTAssertEqual(peerAddress.value as? String, "10.9.0.1")
        peerPresets.tap()
        app.buttons["10.7.0.1"].tap()
        saveConfiguration()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["deviceControlMode"].tap()
        app.buttons["ESP32 NCM"].tap()
        app.buttons["esp32ControlSettings"].tap()
        XCTAssertTrue(app.navigationBars["ESP32 控制"].waitForExistence(timeout: 5))
    }
    private func openProviders(_ app: XCUIApplication) {
        XCTAssertFalse(app.buttons["openProviders"].exists)
        app.buttons["设置"].tap()
        XCTAssertTrue(app.buttons["openProviders"].waitForExistence(timeout: 5))
        app.buttons["openProviders"].tap()
        XCTAssertTrue(app.navigationBars["供应商"].waitForExistence(timeout: 5))
    }
    private func closeProviders(_ app: XCUIApplication) {
        app.navigationBars["供应商"].buttons["BackButton"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        app.buttons["关闭"].tap()
    }
    private func addProvider(_ app: XCUIApplication, name: String, model: String) {
        app.buttons["addProvider"].tap()
        app.buttons["providerPresetCustom"].tap()
        let address = app.textFields["providerURL"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap(); address.typeText("https://fixture.invalid/v1")
        let field = app.textFields["providerName"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.tap(); field.typeText(name)
        app.buttons["addProviderModel"].tap()
        app.alerts.textFields.firstMatch.typeText(model)
        app.alerts.buttons["添加"].tap()
        app.buttons["saveProvider"].tap()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5))
    }
    func testMultipleProvidersAndSessionModelSelection() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-test-composer-models"]
        app.launch()
        openProviders(app)
        XCTAssertTrue(app.staticTexts["Fixture One"].exists)
        XCTAssertTrue(app.staticTexts["Fixture Two"].exists)
        capture("providers")
        closeProviders(app); app.buttons["newConversation"].tap()
        let picker = app.buttons["conversationModelPicker"]
        XCTAssertFalse(picker.exists)
        app.textViews["messageInput"].tap()
        app.textViews["messageInput"].tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 5)); picker.tap()
        app.buttons["conversationProviderRow"].tap()
        app.buttons["Fixture Two"].tap()
        XCTAssertEqual(app.buttons["conversationProviderRow"].value as? String, "Fixture Two")
        XCTAssertEqual(app.buttons["conversationModelRow"].value as? String, "model-b")
        XCTAssertEqual(app.buttons["conversationReasoningEffort"].value as? String, "服务商默认")
        XCTAssertFalse(app.buttons["model-b-alt"].exists)
        capture("conversation-model-settings")
        app.buttons["conversationModelRow"].tap()
        app.buttons["model-b-alt"].tap()
        XCTAssertEqual(app.buttons["conversationModelRow"].value as? String, "model-b-alt")
        app.textViews["messageInput"].tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "model-b-alt"), object: picker)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["newConversationToolbar"].tap()
        app.textViews["messageInput"].tap(); app.textViews["messageInput"].tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(picker.label.contains("model-b-alt"))
        capture("conversation-model")
        XCTAssertFalse(app.buttons["deviceControls"].exists)
        XCTAssertFalse(app.buttons["设置"].exists)
        XCTAssertFalse(app.buttons["滚动到最新消息"].exists)
        let add = app.buttons["addAttachment"].frame
        let send = app.buttons["sendMessage"].frame
        XCTAssertEqual(add.midY, send.midY, accuracy: 1)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertFalse(app.buttons["deviceControls"].exists)
        app.buttons["设置"].tap()
        app.buttons["esp32ControlSettings"].tap()
        XCTAssertTrue(app.navigationBars["VPN 回环控制"].waitForExistence(timeout: 5))
    }
    func testComposerActivationPreservesVisibleBottomAndMovesActionsBelowText() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-test-composer-history"]
        app.launch()
        app.staticTexts["新会话"].firstMatch.tap()
        let input = app.textViews["messageInput"]
        let last = app.staticTexts["滚动验收最后一条消息"]
        XCTAssertTrue(last.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["conversationModelPicker"].exists)
        print("Collapsed viewport", app.scrollViews["conversationMessages"].value ?? "", "input", input.frame, "last", last.frame)
        let collapsedGap = input.frame.minY - last.frame.maxY
        let add = app.buttons["addAttachment"]
        let send = app.buttons["sendMessage"]
        XCTAssertEqual(add.frame.midY, send.frame.midY, accuracy: 1)
        XCTAssertLessThan(abs(add.frame.midY - input.frame.midY), 2)
        capture("composer-collapsed")
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["conversationModelPicker"].waitForExistence(timeout: 5))
        XCTAssertGreaterThan(add.frame.minY, input.frame.midY)
        XCTAssertGreaterThan(send.frame.minY, input.frame.midY)
        XCTAssertEqual(add.frame.midY, send.frame.midY, accuracy: 1)
        print("Expanded viewport", app.scrollViews["conversationMessages"].value ?? "", "input", input.frame, "last exists", last.exists)
        let bottomKept = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            last.exists && abs(input.frame.minY - last.frame.maxY - collapsedGap) < 12
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [bottomKept], timeout: 5), .completed)
        capture("composer-expanded-keyboard")
        app.scrollViews["conversationMessages"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !app.keyboards.firstMatch.exists && last.exists && abs(input.frame.minY - last.frame.maxY - collapsedGap) < 12
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["conversationModelPicker"].exists)
        capture("composer-keyboard-dismissed")
    }
    func testKeyboardPreservesBottomContentWhileReadingHistory() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-test-composer-history"]
        app.launch()
        app.staticTexts["新会话"].firstMatch.tap()
        let input = app.textViews["messageInput"]
        XCTAssertTrue(app.staticTexts["滚动验收最后一条消息"].waitForExistence(timeout: 5))
        app.scrollViews["conversationMessages"].swipeDown()
        let markers = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "滚动验收 ")).allElementsBoundByIndex
        let visible = markers.filter { $0.frame.minY > 116 && $0.frame.maxY < input.frame.minY }
        guard let selectedMarker = visible.max(by: { $0.frame.maxY < $1.frame.maxY }) else { return XCTFail("缺少底部可见的历史消息") }
        let marker = app.staticTexts[selectedMarker.label]
        let gap = input.frame.minY - marker.frame.maxY
        print("History before", app.scrollViews["conversationMessages"].value ?? "", marker.label, "gap", gap)
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let preserved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            marker.exists && abs(input.frame.minY - marker.frame.maxY - gap) < 12
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [preserved], timeout: 5), .completed)
        print("History after", app.scrollViews["conversationMessages"].value ?? "", "gap", input.frame.minY - marker.frame.maxY)
        capture("composer-history-keyboard")
        app.scrollViews["conversationMessages"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !app.keyboards.firstMatch.exists && marker.exists && abs(input.frame.minY - marker.frame.maxY - gap) < 12
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)
        capture("composer-history-keyboard-dismissed")
    }
    func testProviderRemovalNeedsConfirmationAndCanBeRestored() {
        let app = launch(); openProviders(app)
        addProvider(app, name: "Recoverable", model: "model-a")
        app.staticTexts["Recoverable"].swipeLeft(); app.buttons["移除"].tap()
        XCTAssertTrue(app.buttons["移除供应商"].waitForExistence(timeout: 3))
        capture("provider-removal-confirmation")
        app.buttons["取消"].tap()
        XCTAssertTrue(app.staticTexts["Recoverable"].exists)
        app.staticTexts["Recoverable"].swipeLeft(); app.buttons["移除"].tap()
        app.buttons["移除供应商"].tap()
        XCTAssertTrue(app.buttons["恢复"].waitForExistence(timeout: 3))
        app.buttons["恢复"].tap()
        XCTAssertFalse(app.buttons["恢复"].exists)
        XCTAssertTrue(app.staticTexts["Recoverable"].exists)
        capture("provider-restored")
    }
    func testHistoricalDemoStopDoesNotReplayOnReopen() {
        let app = launch(demo: true)
        XCTAssertTrue(app.staticTexts["新会话"].waitForExistence(timeout: 10))
        app.staticTexts["新会话"].tap()
        app.buttons["suggestedPrompt"].tap(); app.buttons["sendMessage"].tap()
        XCTAssertTrue(app.buttons["approveTool"].waitForExistence(timeout: 10))
        app.buttons["stopRun"].tap()
        XCTAssertTrue(app.staticTexts["已停止；已发出的动作可能已执行，请核对设备"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["approveTool"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.staticTexts["查看演示画面，点击计数器一次，再检查结果"].firstMatch.tap()
        XCTAssertFalse(app.buttons["stopRun"].exists)
        XCTAssertFalse(app.buttons["approveTool"].exists)
    }
    func testSavedProviderKeyUsesMaskAndKeepsExistingValue() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-test-provider-key"]
        app.launch(); openProviders(app)
        app.staticTexts["Key Fixture"].tap()
        let key = app.secureTextFields["providerKey"]
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        XCTAssertEqual(key.label, "API 密钥")
        XCTAssertEqual(key.value as? String, "已保存密钥")
        key.tap(); key.typeText("UI_TEST_REPLACEMENT")
        app.buttons["saveProvider"].tap(); app.staticTexts["Key Fixture"].tap()
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        XCTAssertEqual(key.value as? String, "已保存密钥")
        XCTAssertFalse(app.staticTexts["API 密钥（留空保留原值）"].exists)
        capture("saved-provider-key-mask")
        // Saving without replacement retains the stored credential and mask.
        app.buttons["saveProvider"].tap(); app.staticTexts["Key Fixture"].tap()
        XCTAssertEqual(key.value as? String, "已保存密钥")
        let address = app.textFields["providerURL"]
        address.tap(); address.typeText("/proxy")
        app.textFields["providerName"].tap()
        XCTAssertNotEqual(key.value as? String, "已保存密钥")
        app.buttons["取消"].tap(); app.staticTexts["Key Fixture"].tap()
        XCTAssertEqual(key.value as? String, "已保存密钥")
    }
    func testSupplierCreationPresetsAndCustomBlankEditor() {
        continueAfterFailure = false
        let app = launch(); openProviders(app)
        for (choice, name, url) in [
            ("providerPresetOpenAI", "OpenAI", "https://api.openai.com/v1"),
            ("providerPresetOpenRouter", "OpenRouter", "https://openrouter.ai/api/v1"),
            ("providerPresetCustom", "", "")
        ] {
            app.buttons["addProvider"].tap()
            XCTAssertTrue(app.navigationBars["添加供应商"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.textFields["providerName"].exists)
            XCTAssertTrue(app.buttons["providerPresetOpenAI"].exists)
            XCTAssertTrue(app.buttons["providerPresetOpenRouter"].exists)
            XCTAssertTrue(app.buttons["providerPresetCustom"].exists)
            if choice == "providerPresetOpenAI" { capture("supplier-presets") }
            app.buttons[choice].tap()
            let nameField = app.textFields["providerName"], address = app.textFields["providerURL"]
            XCTAssertTrue(nameField.waitForExistence(timeout: 5))
            XCTAssertEqual(nameField.value as? String, name.isEmpty ? "名称" : name)
            XCTAssertEqual(address.value as? String, url.isEmpty ? "HTTPS API 基础地址" : url)
            XCTAssertFalse(app.buttons["providerProtocol"].exists)
            let api = app.buttons["providerInferenceAPI"]
            XCTAssertTrue(api.label.contains("API格式"))
            api.tap()
            XCTAssertTrue(app.buttons["OpenAI Chat Completions"].exists)
            XCTAssertTrue(app.buttons["OpenAI Responses"].exists)
            app.buttons["OpenAI Chat Completions"].tap()
            capture(choice)
            app.buttons["取消"].tap()
            XCTAssertTrue(app.navigationBars["供应商"].waitForExistence(timeout: 5))
        }
    }
    func testLocalEmbeddedSystemSafariHTTPCallback() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--ui-test-chatgpt-loopback"]
        app.launch(); openProviders(app); app.buttons["addProvider"].tap(); app.buttons["ChatGPT 订阅"].tap()
        app.swipeUp(); app.swipeUp()
        let start = app.buttons["chatGPTLoopbackEmbeddedSafari"]
        XCTAssertTrue(start.waitForExistence(timeout: 5)); start.tap()
        XCTAssertTrue(app.staticTexts["本地浏览器回调实验：HTTP 回调验证成功，监听已释放"].waitForExistence(timeout: 15), app.debugDescription)
        capture("chatgpt-local-embedded-system-safari-callback")
    }
    func testLocalSafariLoopbackReceivesCallbackWhileBackgrounded() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--ui-test-chatgpt-loopback"]
        app.launch(); openProviders(app); app.buttons["addProvider"].tap(); app.buttons["ChatGPT 订阅"].tap()
        app.swipeUp(); app.swipeUp()
        let start = app.buttons["chatGPTLoopbackSafari"]
        XCTAssertTrue(start.waitForExistence(timeout: 5)); start.tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        let foreground = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in safari.state == .runningForeground }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [foreground], timeout: 5), .completed)
        app.activate()
        XCTAssertTrue(app.staticTexts["本地浏览器回调实验：HTTP 回调验证成功，监听已释放"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["chatGPTLoopbackLifecycle"].label.contains("background"), app.debugDescription)
        capture("chatgpt-local-safari-background-callback")
    }
    func testLocalSystemBrowserHTTPCallbackAndCancellation() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--ui-test-chatgpt-loopback"]
        app.launch(); openProviders(app); app.buttons["addProvider"].tap(); app.buttons["ChatGPT 订阅"].tap()
        app.swipeUp(); app.swipeUp()
        let start = app.buttons["chatGPTLoopbackStart"]
        XCTAssertTrue(start.waitForExistence(timeout: 5)); start.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Continue", "继续"] {
            if app.buttons[label].waitForExistence(timeout: 1) { app.buttons[label].tap(); break }
            if springboard.buttons[label].waitForExistence(timeout: 1) { springboard.buttons[label].tap(); break }
        }
        let success = app.staticTexts["本地浏览器回调实验：HTTP 回调验证成功，监听已释放"]
        XCTAssertTrue(success.waitForExistence(timeout: 15), app.debugDescription)
        capture("chatgpt-local-system-browser-callback")
        app.buttons["chatGPTLoopbackWait"].tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消", "Done", "完成"])).firstMatch
        if cancel.waitForExistence(timeout: 3) { cancel.tap() }
        XCTAssertTrue(app.staticTexts["本地浏览器回调实验：已取消，监听已释放"].waitForExistence(timeout: 5))
        app.buttons["chatGPTLoopbackWait"].tap()
        XCTAssertTrue(app.staticTexts["本地浏览器回调实验：超时，监听已释放"].waitForExistence(timeout: 16))
        capture("chatgpt-local-browser-timeout")
    }
    func testSubscriptionPresetLoginCancellationAndNoAPIKey() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--ui-test-chatgpt-auth", "--ui-test-chatgpt-auth-wait"]; app.launch(); openProviders(app)
        app.buttons["addProvider"].tap()
        for title in ["OpenAI", "OpenRouter", "ChatGPT 订阅", "自定义供应商"] { XCTAssertTrue(app.buttons[title].exists) }
        app.buttons["ChatGPT 订阅"].tap()
        XCTAssertTrue(app.buttons["chatGPTSignIn"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.secureTextFields["providerKey"].exists)
        XCTAssertFalse(app.textFields["providerURL"].exists)
        app.buttons["chatGPTSignIn"].tap()
        XCTAssertTrue(app.buttons["chatGPTCancelSignIn"].waitForExistence(timeout: 5))
        app.buttons["chatGPTCancelSignIn"].tap()
        XCTAssertTrue(app.staticTexts["ChatGPT 登录已取消"].waitForExistence(timeout: 5))
        capture("chatgpt-subscription-login-cancel")
        app.buttons["取消"].tap()
        XCTAssertFalse(app.buttons["chatGPTSignIn"].exists)
        app.buttons["addProvider"].tap(); app.buttons["providerPresetChatGPTSubscription"].tap()
        let name = app.textFields["providerName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8) + "Subscription Fixture")
        app.buttons["saveProvider"].tap()
        XCTAssertTrue(app.navigationBars["供应商"].waitForExistence(timeout: 5), app.debugDescription)
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "provider-", "Subscription Fixture")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5), app.debugDescription)
    }
    func testSubscriptionSignedMockLoginModelsAndLogout() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--ui-test-chatgpt-auth"]; app.launch(); openProviders(app)
        app.buttons["addProvider"].tap(); app.buttons["ChatGPT 订阅"].tap()
        let login = app.buttons["chatGPTSignIn"]; XCTAssertTrue(login.waitForExistence(timeout: 5)); login.tap()
        XCTAssertFalse(app.buttons["chatGPTAccount"].exists)
        let account = app.descendants(matching: .any)["chatGPTAccount"]
        XCTAssertTrue(account.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.staticTexts["chatGPTConnectionStatus"].exists)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "已获订阅额度授权")).firstMatch.exists)
        let displayedAccount = account.label + " " + (account.value as? String ?? "")
        XCTAssertTrue(displayedAccount.contains("local-fixture@example.invalid"), app.debugDescription)
        XCTAssertFalse(displayedAccount.contains(" · "), displayedAccount)
        XCTAssertFalse(login.exists)
        XCTAssertFalse(app.buttons["启用 ChatGPT 套餐额度"].exists)
        XCTAssertFalse(app.buttons["连接其他账户／工作区"].exists)
        XCTAssertFalse(app.staticTexts["ChatGPT 身份已连接；请核对订阅权限和模型"].exists)
        XCTAssertFalse(app.staticTexts["通过系统浏览器连接 ChatGPT；身份登录还需订阅额度授权。仅对已授权模型使用套餐额度，不自动改用付费 API。"].exists)
        XCTAssertFalse(app.staticTexts["仅获授权的账户／模型使用订阅额度，受套餐与工作区限制。HTTP 请求必须 store=false、stream=true，发送本地上下文；不支持 previous_response_id。"].exists)
        app.swipeUp()
        XCTAssertTrue(app.buttons["providerModel-fixture-vision"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["providerModel-fixture-vision"].value as? String, "已选中")
        XCTAssertFalse(app.staticTexts["设置仅用于此供应商的当前模型；可用档位以模型能力为准。"].exists)
        XCTAssertFalse(app.staticTexts["请选择此账户列表中的模型；列表不保证所有能力或额度可用。"].exists)
        capture("chatgpt-signed-local-login-models")
        app.swipeDown(); app.swipeDown()
        let logout = app.buttons["chatGPTDisconnect"]; XCTAssertTrue(logout.waitForExistence(timeout: 5)); logout.tap()
        XCTAssertTrue(app.staticTexts["已退出，服务器已确认结束此刷新会话。"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["chatGPTConnectionStatus"].label, "未连接 ChatGPT")
        XCTAssertTrue(login.waitForExistence(timeout: 5))
        capture("chatgpt-local-logout")
    }
    func testSubscriptionBadSignatureMockIsNeverConnected() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--ui-test-chatgpt-auth", "--ui-test-chatgpt-auth-invalid"]; app.launch(); openProviders(app)
        app.buttons["addProvider"].tap(); app.buttons["ChatGPT 订阅"].tap()
        let login = app.buttons["chatGPTSignIn"]; XCTAssertTrue(login.waitForExistence(timeout: 5)); login.tap()
        XCTAssertTrue(app.staticTexts["ChatGPT 身份签名、账号或授权回调校验失败"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["chatGPTConnectionStatus"].label, "未连接 ChatGPT")
        XCTAssertFalse(app.buttons["chatGPTAccount"].exists)
        capture("chatgpt-local-invalid-signature")
    }
    func testResponsesContextSelectionPersistsAndChatResetsChain() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--ui-test-composer-models"]; app.launch()
        openProviders(app); app.staticTexts["Fixture One"].tap()
        XCTAssertFalse(app.buttons["providerProtocol"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["providerKind"].exists)
        let api = app.buttons["providerInferenceAPI"], context = app.buttons["providerContextPolicy"]
        XCTAssertTrue(api.waitForExistence(timeout: 5)); api.tap(); app.buttons["OpenAI Responses"].tap()
        XCTAssertTrue(context.waitForExistence(timeout: 3)); context.tap()
        app.buttons["服务端响应链 · 保存远端响应"].tap()
        capture("responses-context-setting")
        app.buttons["saveProvider"].tap(); app.staticTexts["Fixture One"].tap()
        XCTAssertTrue(api.label.contains("Responses")); XCTAssertTrue(context.label.contains("服务端响应链"))
        api.tap(); app.buttons["OpenAI Chat Completions"].tap(); XCTAssertFalse(context.exists)
        app.buttons["saveProvider"].tap(); app.staticTexts["Fixture One"].tap()
        XCTAssertTrue(api.label.contains("Chat Completions")); XCTAssertFalse(context.exists)
    }
    func testDiscoverModelsBrowseAllAndSelectCachedModelInConversation() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--ui-test-model-catalog", "-AppleLanguages", "(zh-Hans)"]; app.launch()
        openProviders(app); app.staticTexts["Catalog Fixture"].tap()
        XCTAssertTrue(app.buttons["fetchModels"].waitForExistence(timeout: 5)); app.buttons["fetchModels"].tap()
        XCTAssertTrue(app.buttons["providerModel-fixture-vision"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["providerModel-fixture-vision"].value as? String, "已选中")
        XCTAssertFalse(app.staticTexts["图片：未知"].firstMatch.exists)
        XCTAssertFalse(app.buttons["providerModel-fixture-vision"].label.contains("支持图片输入"))
        XCTAssertFalse(app.buttons["providerModel-fixture-vision"].label.contains("支持文本生成"))
        XCTAssertFalse(app.textFields["parameter-temperature"].exists)
        XCTAssertFalse(app.staticTexts["接口报告的能力"].exists)
        XCTAssertFalse(app.buttons["providerModel-fixture-seventh"].exists)
        app.swipeUp()
        let effort = app.buttons["reasoningEffort"]
        XCTAssertTrue(effort.waitForExistence(timeout: 3)); effort.tap(); app.buttons["高"].tap()
        XCTAssertFalse(app.textFields["parameter-temperature"].exists)
        let browse = app.buttons["browseAllProviderModels"]
        XCTAssertTrue(browse.waitForExistence(timeout: 5)); browse.tap()
        XCTAssertTrue(app.navigationBars["选择模型"].waitForExistence(timeout: 5))
        let search = app.searchFields["搜索模型 ID"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("fixture-seventh")
        let option = app.buttons["providerModelOption-fixture-seventh"]
        XCTAssertTrue(option.waitForExistence(timeout: 3))
        capture("all-models-search")
        option.tap()
        app.swipeUp()
        let selected = app.buttons["providerModel-fixture-seventh"]
        XCTAssertTrue(selected.waitForExistence(timeout: 3))
        XCTAssertEqual(selected.value as? String, "已选中")
        XCTAssertFalse(app.textFields["providerModel"].exists)
        XCTAssertTrue(app.buttons["providerModel-fixture-fifth"].exists)
        XCTAssertFalse(app.buttons["providerModel-fixture-sixth"].exists)
        XCTAssertLessThan(app.buttons["providerModel-fixture-fifth"].frame.minY, selected.frame.minY)
        XCTAssertLessThan(selected.frame.minY, app.buttons["browseAllProviderModels"].frame.minY)
        capture("compact-model-chips")
        app.buttons["saveProvider"].tap(); closeProviders(app); app.buttons["newConversation"].tap()
        let picker = app.buttons["conversationModelPicker"]
        // Match the existing composer-model test: complete the focus transition
        // after dismissing an editor keyboard before expecting its action row.
        app.textViews["messageInput"].tap(); app.textViews["messageInput"].tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(picker.label.contains("fixture-seventh")); picker.tap()
        let providerRow = app.buttons["conversationProviderRow"]
        let modelRow = app.buttons["conversationModelRow"]
        let effortRow = app.buttons["conversationReasoningEffort"]
        capture("conversation-three-settings-open")
        XCTAssertTrue(providerRow.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(providerRow.value as? String, "Catalog Fixture")
        XCTAssertEqual(modelRow.value as? String, "fixture-seventh")
        XCTAssertEqual(effortRow.value as? String, "服务商默认")
        XCTAssertFalse(app.buttons["fixture-other"].exists)
        capture("conversation-three-settings-rows")
        modelRow.tap(); app.buttons["fixture-other"].tap()
        XCTAssertEqual(modelRow.value as? String, "fixture-other")
        modelRow.tap(); app.buttons["fixture-vision"].tap()
        XCTAssertEqual(effortRow.value as? String, "高")
        effortRow.tap()
        capture("conversation-reasoning-popup")
        app.buttons["低"].tap()
        XCTAssertEqual(effortRow.value as? String, "低")
        modelRow.tap(); app.buttons["fixture-other"].tap()
        XCTAssertEqual(effortRow.value as? String, "服务商默认")
        modelRow.tap(); app.buttons["fixture-vision"].tap()
        XCTAssertEqual(effortRow.value as? String, "低")
        effortRow.tap(); app.buttons["服务商默认（低）"].tap()
        XCTAssertEqual(effortRow.value as? String, "服务商默认（低）")
        app.textViews["messageInput"].tap()
        XCTAssertFalse(picker.label.contains("低"))
        capture("discovered-model-selection")
    }
}
