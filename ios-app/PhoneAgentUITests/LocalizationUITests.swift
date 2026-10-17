import XCTest

@MainActor final class LocalizationUITests: XCTestCase {
    func testEnglishSettingsAndProviderForm() { verify(language: "en", chinese: false) }
    func testChineseSettingsAndProviderForm() { verify(language: "zh-Hans", chinese: true) }

    private func verify(language: String, chinese: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(\(language))", "-AppleLocale", chinese ? "zh_CN" : "en_US"]
        app.launch()
        let settings = app.buttons[chinese ? "设置" : "Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), app.debugDescription)
        settings.tap()
        XCTAssertTrue(app.staticTexts[chinese ? "执行模式" : "Execution mode"].exists)
        XCTAssertEqual(app.buttons["openBackgroundSettings"].label, chinese ? "模式" : "Mode")
        app.buttons["openBackgroundSettings"].tap()
        XCTAssertTrue(app.navigationBars[chinese ? "后台执行" : "Background execution"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["backgroundMechanism.audio"].exists)
        XCTAssertEqual(app.switches["backgroundMechanism.location"].label, chinese ? "定位" : "Location")
        capture("background-\(language)")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["openProviders"].tap()
        XCTAssertTrue(app.navigationBars[chinese ? "供应商" : "Provider"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["addProvider"].tap()
        app.buttons["providerPresetCustom"].tap()
        XCTAssertTrue(app.textFields["providerName"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["providerName"].placeholderValue, chinese ? "名称" : "Name")
        XCTAssertEqual(app.secureTextFields["providerKey"].label, chinese ? "API 密钥" : "API key")
        app.buttons["saveProvider"].tap()
        let invalidURL = app.staticTexts[chinese ? "请填写不含凭据、查询参数或片段的 HTTPS 基础地址" : "Enter an HTTPS base URL without credentials, query parameters, or a fragment"]
        for _ in 0..<4 where !invalidURL.exists { app.swipeUp() }
        XCTAssertTrue(invalidURL.waitForExistence(timeout: 5), app.debugDescription)
        capture("provider-validation-\(language)")
        app.terminate()
    }
    private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }
}
