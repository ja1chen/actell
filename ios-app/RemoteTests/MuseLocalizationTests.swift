import XCTest
@testable import PhoneAgent

final class MuseLocalizationTests: XCTestCase {
    private func languageBundle(_ language: String, in bundle: Bundle = .main) throws -> Bundle {
        let path = try XCTUnwrap(bundle.path(forResource: language, ofType: "lproj"))
        return try XCTUnwrap(Bundle(path: path))
    }
    func testMuseDiagnosticMessagePreservesDetailsAndIdentifierInBothLanguages() throws {
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let widget = try XCTUnwrap(Bundle(url: plugins.appendingPathComponent("PhoneAgentLiveActivity.appex")))
        for target in [Bundle.main, widget] {
            let english = try languageBundle("en", in: target), chinese = try languageBundle("zh-Hans", in: target)
            for (key, translation) in [("Muse Gadget Service", "Muse Gadget 服务"), ("Add Muse", "添加 Muse"),
                                       ("Waiting for Muse", "等待 Muse 申请"), ("Remove Device", "移除设备")] {
                XCTAssertEqual(english.localizedString(forKey: key, value: nil, table: nil), key)
                XCTAssertEqual(chinese.localizedString(forKey: key, value: nil, table: nil), translation)
            }
        }
        let en = try languageBundle("en"), zh = try languageBundle("zh-Hans")
        let disclosure = "Screenshots and app information may be sent through Muse to its service or model. Allowed actions run without further prompts."
        XCTAssertEqual(en.localizedString(forKey: disclosure, value: nil, table: nil), disclosure)
        let translatedDisclosure = zh.localizedString(forKey: disclosure, value: nil, table: nil)
        XCTAssertFalse(translatedDisclosure.isEmpty)
        XCTAssertNotEqual(translatedDisclosure, disclosure)
        let message = "Synthetic detail", identifier = "0123456789abcdef"
        XCTAssertEqual(String(localized: "\(message) (Diagnostic ID: \(identifier))", bundle: en),
                       "Synthetic detail (Diagnostic ID: 0123456789abcdef)")
        XCTAssertEqual(String(localized: "\(message) (Diagnostic ID: \(identifier))", bundle: zh),
                       "Synthetic detail（诊断编号：0123456789abcdef）")
    }
}
