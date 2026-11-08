import XCTest
@testable import PhoneAgent

final class ScreenInformationModeTests: XCTestCase {
    func testLegacyChoiceMigratesOnceAndExplicitModeWins() throws {
        for enabled in [false, true] {
            let suite = "screen-information-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(enabled, forKey: "accessibilityTreeEnabled")
            let expected: ScreenInformationMode = enabled ? .screenshotAndAccessibility : .screenshot
            XCTAssertEqual(ScreenInformationMode.load(from: defaults), expected)
            XCTAssertEqual(defaults.string(forKey: ScreenInformationMode.defaultsKey), expected.rawValue)
            XCTAssertNil(defaults.object(forKey: "accessibilityTreeEnabled"))
            defaults.set(ScreenInformationMode.automatic.rawValue, forKey: ScreenInformationMode.defaultsKey)
            defaults.set(enabled, forKey: "accessibilityTreeEnabled")
            XCTAssertEqual(ScreenInformationMode.load(from: defaults), .automatic)
        }
    }
    func testMissingOrInvalidPreferenceDefaultsToScreenshotAndAllChoicesReload() throws {
        let suite = "screen-information-\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ScreenInformationMode.load(from: defaults), .screenshot)
        defaults.set("unknown", forKey: ScreenInformationMode.defaultsKey)
        defaults.set(true, forKey: "accessibilityTreeEnabled")
        XCTAssertEqual(ScreenInformationMode.load(from: defaults), .screenshot)
        for mode in ScreenInformationMode.allCases {
            defaults.set(mode.rawValue, forKey: ScreenInformationMode.defaultsKey)
            XCTAssertEqual(ScreenInformationMode.load(from: defaults), mode)
        }
    }
    func testOnlyAutomaticOffersTheModelAnObservationChoice() throws {
        for mode in ScreenInformationMode.allCases {
            let schema = try XCTUnwrap(DeviceTool.parameters(for: "screenshot", screenInformationMode: mode).foundation as? [String: Any])
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            if mode == .automatic {
                let choice = try XCTUnwrap(properties["mode"] as? [String: Any])
                XCTAssertEqual(choice["enum"] as? [String], ["screenshot", "accessibility", "screenshot_and_accessibility"])
                XCTAssertEqual(schema["required"] as? [String], ["mode"])
            } else {
                XCTAssertEqual(Set(properties.keys), Set(["description"]))
                XCTAssertEqual(schema["required"] as? [String], [])
            }
            XCTAssertTrue(DeviceTool.description(for: "screenshot", screenInformationMode: mode).contains(mode.toolInstruction))
        }
        let remote = try XCTUnwrap(DeviceTool.parameters(for: "screenshot").foundation as? [String: Any])
        XCTAssertEqual(Set(try XCTUnwrap(remote["properties"] as? [String: Any]).keys), Set(["description"]))
        XCTAssertEqual(remote["required"] as? [String], [])
    }
    func testAccessibilityOnlyHistoryDoesNotShowMissingScreenshotPlaceholderOrRewriteContent() {
        let result = #"{"screen_information_mode":"accessibility","accessibility":{"status":"available","nodes":[{"label":"Full content"}]}}"#
        let step = ToolStep(callID: "observation", name: "screenshot", state: .succeeded, detail: "", result: result)
        XCTAssertFalse(step.expectsScreenshotPreview)
        XCTAssertTrue(step.displayResult.contains("nodeCount")); XCTAssertFalse(step.displayResult.contains("Full content"))
        XCTAssertEqual(step.result, result)
        let old = ToolStep(callID: "old", name: "screenshot", state: .succeeded, detail: "", result: #"{"width":390,"height":844}"#)
        XCTAssertTrue(old.expectsScreenshotPreview)
    }
}
