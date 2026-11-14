import XCTest

@MainActor final class MuseConnectionUITests: XCTestCase {
    func testEnglishMuseSetupUsesLocalizedLabels() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        app.buttons["Settings"].tap()
        let entry = app.buttons["openMuseConnection"]
        for _ in 0..<4 where !entry.isHittable { app.swipeUp() }
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        XCTAssertTrue(app.staticTexts["museNoDevices"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["museNoDevices"].label, "No devices added")
        XCTAssertTrue(app.switches["museAllowConnection"].label.contains("Muse Gadget Service"))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "museServiceStatus").firstMatch.value as? String, "Stopped")
        XCTAssertFalse(app.buttons["museAddCompanion"].exists)
    }
    private func open(_ flag: String? = nil, environment: [String: String] = [:]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"] + (flag.map { [$0] } ?? [])
        app.launchEnvironment.merge(environment, uniquingKeysWith: { _, new in new })
        app.launch()
        app.buttons["设置"].tap()
        let entry = app.buttons["openMuseConnection"]
        for _ in 0..<4 where !entry.isHittable { app.swipeUp() }
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertEqual(entry.label, "Muse Gadget")
        if flag == nil {
            let settings = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            settings.name = "muse-gadget-settings-entry"; settings.lifetime = .keepAlways; add(settings)
        }
        entry.tap()
        return app
    }
    func testServiceChoicePersistsAcrossProcessRelaunchEvenWhenStartupFails() {
        let suite = "actell.muse.preference-ui." + UUID().uuidString
        let environment = ["MUSE_PREFERENCE_TEST_SUITE": suite]
        let app = open("--ui-test-muse-preference", environment: environment.merging(["MUSE_PREFERENCE_TEST_RESET": "1"]) { _, new in new })
        defer {
            app.terminate()
            app.launchEnvironment = environment.merging(["MUSE_PREFERENCE_TEST_RESET": "1"]) { _, new in new }
            app.launch(); app.terminate()
        }
        let toggle = app.switches["museAllowConnection"]
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.switches.firstMatch.tap()
        XCTAssertTrue(app.alerts["操作未完成"].waitForExistence(timeout: 3))
        app.alerts.buttons["好"].tap()
        XCTAssertEqual(toggle.value as? String, "1")
        app.terminate()

        let second = open("--ui-test-muse-preference", environment: environment)
        XCTAssertEqual(second.switches["museAllowConnection"].value as? String, "1")
        second.switches["museAllowConnection"].switches.firstMatch.tap()
        XCTAssertEqual(second.switches["museAllowConnection"].value as? String, "0")
        second.terminate()

        let third = open("--ui-test-muse-preference", environment: environment)
        XCTAssertEqual(third.switches["museAllowConnection"].value as? String, "0")
        third.terminate()
    }
    func testNormalSetupHidesDeveloperToolsAndDoesNotOfferManualSecrets() {
        let app = open()
        XCTAssertTrue(app.staticTexts["museNoDevices"].waitForExistence(timeout: 5))
        for id in ["musePrepareIdentity", "museStartConnection", "museImportCertificate", "museAddClient"] {
            XCTAssertFalse(app.buttons[id].exists)
        }
        XCTAssertFalse(app.textFields["museServerHost"].exists)
        XCTAssertFalse(app.buttons["Muse 开发工具"].exists)
        XCTAssertFalse(app.buttons["蓝牙安全配对实验"].exists)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "muse-minimal-empty"; screenshot.lifetime = .keepAlways; add(screenshot)
        XCTAssertEqual(app.switches["museAllowConnection"].value as? String, "0")
        XCTAssertTrue(app.navigationBars["Muse Gadget"].exists)
        XCTAssertTrue(app.switches["museAllowConnection"].label.contains("Muse Gadget 服务"))
        XCTAssertFalse(app.buttons["museAddCompanion"].exists)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "museServiceStatus").firstMatch.value as? String, "已停止")
        XCTAssertFalse(app.textFields["museClientNameInput"].exists)
    }
    func testPairedDevicePermissionsStayIndependentAndCanBeRemoved() {
        let app = open("--ui-test-muse-device")
        let device = app.buttons["museDevice-11111111-1111-4111-8111-111111111111"]
        XCTAssertTrue(device.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["musePeerStatus-11111111-1111-4111-8111-111111111111"].label, "权限未开放")
        let list = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        list.name = "muse-device-list-alignment"; list.lifetime = .keepAlways; add(list)
        device.tap()
        let name = app.textFields["museDeviceName"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        let previousName = name.value as? String ?? ""
        name.tap()
        // The field is right-aligned; its center can place the caret before the value.
        name.coordinate(withNormalizedOffset: CGVector(dx: 0.999, dy: 0.5)).tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previousName.utf16.count))
        name.typeText("Living Room Muse")
        let screenshotScope = app.switches["musePermission-screenshot"]
        XCTAssertTrue(screenshotScope.waitForExistence(timeout: 3))
        XCTAssertEqual(screenshotScope.value as? String, "0")
        XCTAssertEqual(app.switches["musePermission-list_apps"].value as? String, "0")
        XCTAssertEqual(app.switches["musePermission-control"].value as? String, "0")
        XCTAssertTrue(app.staticTexts["museCapabilityDataDisclosure"].exists)
        XCTAssertFalse(app.switches["我已核对可信 USB 交付的设备编号"].exists)
        // SwiftUI exposes both a full-row switch and a nested UISwitch on iOS 27.
        // Tap the actual switch; the row's center is outside its hit target.
        screenshotScope.switches.firstMatch.tap()
        XCTAssertEqual(screenshotScope.value as? String, "1")
        app.buttons["保存"].tap()
        XCTAssertTrue(device.waitForExistence(timeout: 3))
        XCTAssertTrue(device.label.contains("Living Room Muse"))
        device.tap()
        XCTAssertEqual(app.textFields["museDeviceName"].value as? String, "Living Room Muse")
        XCTAssertEqual(screenshotScope.value as? String, "1")
        XCTAssertEqual(app.switches["musePermission-list_apps"].value as? String, "0")
        XCTAssertEqual(app.switches["musePermission-control"].value as? String, "0")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "muse-minimal-permissions"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["museRemoveSelectedDevice"].tap()
        app.sheets.buttons["移除设备"].tap()
        XCTAssertTrue(app.staticTexts["museNoDevices"].waitForExistence(timeout: 3))
    }
    func testUnconfirmedDeviceCannotOpenPermissions() {
        let app = open("--ui-test-muse-pending")
        XCTAssertTrue(app.staticTexts["配对未完成"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["museDevice-11111111-1111-4111-8111-111111111111"].exists)
        XCTAssertEqual(app.switches["museAllowConnection"].value as? String, "0")
        XCTAssertTrue(app.buttons["museRemoveDevice-11111111-1111-4111-8111-111111111111"].exists)
    }
    func testLANRequestRequiresOneLocalApprovalThenEnablesDefaultPermissions() {
        let app = open("--ui-test-muse-request")
        let add = app.buttons["museAddCompanion"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: add)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        let list = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        list.name = "muse-add-row-spacing"; list.lifetime = .keepAlways; self.add(list)
        add.tap()
        let allow = app.buttons["musePairingAllow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["musePairingReject"].exists)
        let request = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        request.name = "slan-request-approval"; request.lifetime = .keepAlways; self.add(request)
        allow.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "musePairingComplete").firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["musePairingAllow"].exists)
        let complete = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        complete.name = "slan-paired-default-permissions"; complete.lifetime = .keepAlways; self.add(complete)
        app.buttons["完成"].tap()
        let device = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "museDevice-")).firstMatch
        XCTAssertTrue(device.waitForExistence(timeout: 5)); device.tap()
        for scope in ["screenshot", "list_apps", "control"] {
            XCTAssertEqual(app.switches["musePermission-" + scope].value as? String, "1")
        }
    }

}
