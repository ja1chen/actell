import XCTest
@testable import PhoneAgent

@MainActor final class MuseDiagnosticsLogTests: XCTestCase {
    func testBoundedPersistentHistoryAndHashedCorrelation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = MuseDiagnosticsLog(directory: directory, capacity: 3)
        for index in 0..<5 {
            log.record("runs.open.rejected", request: "request-private-\(index)", client: "client-private", run: "run-private",
                       code: "control_not_connected", state: ["foreground": "true", "control_ready": "false"])
        }
        XCTAssertNil(log.storageError)
        let restored = MuseDiagnosticsLog(directory: directory, capacity: 3)
        XCTAssertEqual(restored.events.count, 3)
        XCTAssertEqual(restored.events.first?.diagnosticID, MuseDiagnosticsLog.tag("request-private-2"))
        XCTAssertEqual(restored.events.last?.code, "control_not_connected")
        XCTAssertEqual(restored.events.last?.state["foreground"], "true")
        XCTAssertGreaterThan(restored.events.last?.uptime ?? 0, 0)
        let report = restored.report()
        XCTAssertTrue(report.contains("control_ready"))
        XCTAssertFalse(report.contains("request-private"))
        XCTAssertFalse(report.contains("client-private"))
        XCTAssertFalse(report.contains("run-private"))
        // Simulator's host filesystem does not expose iOS data-protection attributes.
        #if !targetEnvironment(simulator)
        let url = directory.appendingPathComponent("muse-admission-v1.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .completeUntilFirstUserAuthentication)
        #endif
    }

    func testStorageFailureIsVisibleAndDoesNotPreventAdmissionDiagnostics() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("file instead of directory".utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let log = MuseDiagnosticsLog(directory: path)
        log.record("runs.open.rejected", code: "not_foreground", state: ["foreground": "false"])
        XCTAssertNotNil(log.storageError)
        XCTAssertEqual(log.events.last?.code, "not_foreground")
        XCTAssertFalse(log.report().contains("storage=ok"))
    }

    func testExportPreservesUnwrittenEventsAndStorageFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let model = AgentViewModel(loadPersistentState: false)
        let log = MuseDiagnosticsLog(directory: directory)
        model.museDiagnostics = log
        log.record("baseline", state: [:])
        XCTAssertNil(log.storageError)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        log.record("runs.open.rejected", code: "not_foreground", state: ["foreground": "false"])
        XCTAssertNotNil(log.storageError)
        XCTAssertEqual(MuseDiagnosticsLog(directory: directory).events.count, 1) // The stale file is still readable.
        let report = model.usbDiagnosticReport()
        XCTAssertTrue(report.contains("runs.open.rejected"))
        XCTAssertTrue(report.contains("not_foreground"))
        XCTAssertTrue(report.contains("storage=" + (log.storageError ?? "missing")))
        XCTAssertFalse(report.contains("storage=ok"))
    }
}
