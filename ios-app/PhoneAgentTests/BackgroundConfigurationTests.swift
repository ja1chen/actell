import XCTest
@testable import PhoneAgent

@MainActor final class BackgroundConfigurationTests: XCTestCase {
    private func store(_ values: [String: Any] = [:]) -> (BackgroundSettingsStore, UserDefaults, String) {
        let name = "background.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.setPersistentDomain(values, forName: name)
        return (BackgroundSettingsStore(defaults: defaults, domain: name), defaults, name)
    }
    func testStandbyActivityDefaultsOnAndChoiceSurvivesResidencyChangesAndReload() {
        let (settings, defaults, name) = store([BackgroundSettingsStore.residentKey: true])
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(settings.standbyActivityEnabled)
        XCTAssertTrue(settings.reservesStandbyActivity)
        settings.setStandbyActivity(false)
        XCTAssertTrue(settings.residentEnabled)
        XCTAssertFalse(settings.reservesStandbyActivity)
        let restored = BackgroundSettingsStore(defaults: defaults, domain: name)
        XCTAssertFalse(restored.standbyActivityEnabled)
        restored.setResident(false)
        restored.setStandbyActivity(true)
        XCTAssertFalse(restored.reservesStandbyActivity)
        restored.setResident(true)
        XCTAssertTrue(restored.reservesStandbyActivity)
        XCTAssertTrue(BackgroundSettingsStore(defaults: defaults, domain: name).reservesStandbyActivity)
    }
    func testAllSixteenSelectionsAndEmptySurviveReload() throws {
        for mask in 0..<16 {
            let (settings, defaults, name) = store()
            defer { defaults.removePersistentDomain(forName: name) }
            for (index, mechanism) in BackgroundMechanism.allCases.enumerated() {
                settings.set(mechanism, selected: mask & (1 << index) != 0)
            }
            let restored = BackgroundSettingsStore(defaults: defaults, domain: name)
            XCTAssertEqual(restored.selection, settings.selection)
            XCTAssertEqual(restored.selection.count, mask.nonzeroBitCount)
        }
    }
    func testNewInstallAndLegacyMigration() {
        for (values, expected) in [([String: Any](), Set<BackgroundMechanism>([.audio])),
                                   (["backgroundPlaybackMode": "audio"], [.audio]),
                                   (["backgroundPlaybackMode": "pictureInPicture"], [.pictureInPicture]),
                                   (["backgroundPlaybackMode": "systemTask"], [.systemTask]),
                                   (["backgroundPlaybackMode": "future"], []),
                                   (["backgroundPlaybackMode": ""], []),
                                   (["backgroundPlaybackMode": 42], []),
                                   (["backgroundResidentEnabled": true], [.audio]),
                                   (["backgroundResidentEnabled": false], [.audio])] {
            let (settings, defaults, name) = store(values)
            defer { defaults.removePersistentDomain(forName: name) }
            XCTAssertEqual(settings.selection, expected)
            XCTAssertEqual(BackgroundSettingsStore(defaults: defaults, domain: name).selection, expected)
            for key in values.keys { XCTAssertNotNil(defaults.persistentDomain(forName: name)?[key]) }
        }
    }
    func testWriteFailureKeepsLegacyDataAndExistingInstallationDoesNotAddLocation() {
        let name = UUID().uuidString, defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.setPersistentDomain([BackgroundSettingsStore.legacyKey: "systemTask"], forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let failed = BackgroundSettingsStore(defaults: defaults, domain: name, writer: { _ in false })
        XCTAssertTrue(failed.selection.isEmpty); XCTAssertNotNil(failed.warning)
        XCTAssertEqual(defaults.persistentDomain(forName: name)?[BackgroundSettingsStore.legacyKey] as? String, "systemTask")
        XCTAssertNil(defaults.persistentDomain(forName: name)?[BackgroundSettingsStore.key])
        defaults.setPersistentDomain([:], forName: name)
        let installed = BackgroundSettingsStore(defaults: defaults, domain: name, existingInstallation: true)
        XCTAssertEqual(installed.selection, [.audio]); XCTAssertFalse(installed.residentEnabled)
    }
    func testRegistrationDomainIsNotExplicitChoice() {
        let name = UUID().uuidString, defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.register(defaults: ["backgroundPlaybackMode": "systemTask", "backgroundResidentEnabled": true])
        let settings = BackgroundSettingsStore(defaults: defaults, domain: name)
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(settings.selection, [.audio]); XCTAssertFalse(settings.residentEnabled)
    }
    func testUnknownValuesRoundTripAndFutureSchemaCannotBeOverwritten() {
        for raw in [#"{"version":2,"selected":["future","audio","future"]}"#,
                    #"{"version":3,"selected":["location"],"unknown":{"x":1}}"#,
                    #"{"version":2,"selected":null}"#, #"{"version":2}"#, "bad"] {
            let bytes = Data(raw.utf8)
            let (settings, defaults, name) = store([BackgroundSettingsStore.key: bytes])
            defer { defaults.removePersistentDomain(forName: name) }
            if raw.contains("future\",\"audio") {
                settings.set(.location, selected: true)
                XCTAssertEqual(settings.configuration.selectedRawValues, ["future", "audio", "location"])
            } else {
                XCTAssertTrue(settings.selection.isEmpty)
                XCTAssertEqual(defaults.data(forKey: BackgroundSettingsStore.key), bytes)
                if raw.contains("\"version\":3") {
                    settings.set(.audio, selected: true)
                    XCTAssertEqual(defaults.data(forKey: BackgroundSettingsStore.key), bytes)
                }
            }
        }
    }
}
