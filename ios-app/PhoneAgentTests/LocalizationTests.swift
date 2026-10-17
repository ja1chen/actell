import XCTest
@testable import PhoneAgent

final class LocalizationTests: XCTestCase {
    private func languageBundle(_ language: String, in bundle: Bundle = .main) throws -> Bundle {
        let path = try XCTUnwrap(bundle.path(forResource: language, ofType: "lproj"))
        return try XCTUnwrap(Bundle(path: path))
    }
    func testAppAndWidgetContainMatchingEnglishAndChineseResources() throws {
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let widget = try XCTUnwrap(Bundle(url: plugins.appendingPathComponent("PhoneAgentLiveActivity.appex")))
        for target in [Bundle.main, widget] {
            let english = try languageBundle("en", in: target)
            let chinese = try languageBundle("zh-Hans", in: target)
            for (key, translation) in [("Settings", "设置"), ("Waiting for confirmation", "等待确认"),
                                       ("Task completed", "任务已完成"), ("Open app", "打开 App"),
                                       ("Background standby", "后台待命"), ("Keep running in background", "后台常驻"),
                                       ("Muse Gadget Service", "Muse Gadget 服务"), ("Add Muse", "添加 Muse"),
                                       ("Waiting for Muse", "等待 Muse 申请"), ("Remove Device", "移除设备")] {
                XCTAssertEqual(english.localizedString(forKey: key, value: nil, table: nil), key)
                XCTAssertEqual(chinese.localizedString(forKey: key, value: nil, table: nil), translation)
            }
        }
    }
    func testCountMessagesSelectEnglishPluralFormsAndKeepChineseCounts() throws {
        let en = try languageBundle("en"), zh = try languageBundle("zh-Hans")
        XCTAssertEqual(String(localized: "Removed \(1) unused files", bundle: en, locale: Locale(identifier: "en")), "Removed 1 unused file")
        XCTAssertEqual(String(localized: "Removed \(2) unused files", bundle: en, locale: Locale(identifier: "en")), "Removed 2 unused files")
        XCTAssertEqual(String(localized: "Removed \(2) unused files", bundle: zh, locale: Locale(identifier: "zh-Hans")), "已清理 2 个未引用文件")
    }
    func testMuseDiagnosticMessagePreservesDetailsAndIdentifierInBothLanguages() throws {
        let en = try languageBundle("en"), zh = try languageBundle("zh-Hans")
        let message = "Synthetic detail", identifier = "0123456789abcdef"
        XCTAssertEqual(String(localized: "\(message) (Diagnostic ID: \(identifier))", bundle: en),
                       "Synthetic detail (Diagnostic ID: 0123456789abcdef)")
        XCTAssertEqual(String(localized: "\(message) (Diagnostic ID: \(identifier))", bundle: zh),
                       "Synthetic detail（诊断编号：0123456789abcdef）")
    }
    func testPrivacyPromptsAndDisplayNamesAreLocalized() throws {
        for (language, name) in [("en", "Actell"), ("zh-Hans", "执言")] {
            let bundle = try languageBundle(language)
            XCTAssertEqual(bundle.localizedString(forKey: "CFBundleDisplayName", value: nil, table: "InfoPlist"), name)
            for key in ["NSLocalNetworkUsageDescription", "NSPhotoLibraryAddUsageDescription", "NSLocationWhenInUseUsageDescription"] {
                let message = bundle.localizedString(forKey: key, value: nil, table: "InfoPlist")
                XCTAssertNotEqual(message, key)
                XCTAssertEqual(message.range(of: "[\\p{Han}]", options: .regularExpression) != nil, language == "zh-Hans")
            }
        }
    }
}
