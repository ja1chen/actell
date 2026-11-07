// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import CoreDeviceBackend

final class NativeAccessibilityDiagnosticTests: XCTestCase {
    func testRemoteErrorDetailsAreBoundedAndDescriptionsAreExcluded() throws {
        let data = Data(#"{"version":1,"selection":"hit_test","phase":"selection_verify","request_type":6,"elapsed_ms":80,"phase_elapsed_ms":4,"subscription_ack_ms":10,"target_pid":7,"observed_pid":8,"error_type":"object","remote_code":"-25204","remote_domain":"com.apple.Accessibility","has_result":false,"NSLocalizedDescription":"PRIVATE_SCREEN_TEXT"}"#.utf8)
        let fields = try XCTUnwrap(NativeAccessibilityDiagnostic.decode(data, requestID: 42)).logFields
        for value in ["axRequest=42", "axPhase=selection_verify", "axRequestType=6", "axRemoteCode=-25204", "axRemoteDomain=com.apple.Accessibility", "axHasResult=false", "axTargetPID=7", "axObservedPID=8"] {
            XCTAssertTrue(fields.contains(value), value)
        }
        XCTAssertFalse(fields.contains("PRIVATE_SCREEN_TEXT"))
        XCTAssertFalse(fields.contains("NSLocalizedDescription"))
    }
    func testInvalidOptionalMetadataAndUntrustedLogFieldsAreIgnored() throws {
        for data in [Data(), Data("invalid".utf8), Data(repeating: 65, count: 2049), Data(#"{"version":2}"#.utf8)] {
            XCTAssertNil(NativeAccessibilityDiagnostic.decode(data, requestID: 1))
        }
        let data = Data(#"{"version":1,"selection":"hit_test","phase":"selection_initial","elapsed_ms":1,"phase_elapsed_ms":1,"error_type":"boolean","remote_boolean":false,"remote_domain":"private\ntext", "remote_code":"failed injected=true"}"#.utf8)
        let fields = try XCTUnwrap(NativeAccessibilityDiagnostic.decode(data, requestID: 1)).logFields
        XCTAssertTrue(fields.contains("axRemoteDomainRedacted=true"))
        XCTAssertTrue(fields.contains("axRemoteBoolean=false"))
        XCTAssertFalse(fields.contains("private")); XCTAssertFalse(fields.contains("injected"))
    }
    func testPIDFallbackReportsItsOwnPhaseAndRetainsInitialReason() throws {
        let data = Data(#"{"version":1,"selection":"explicit_pid","phase":"target_validation","elapsed_ms":20,"phase_elapsed_ms":2,"target_pid":7,"fallback_from":"selection_initial","initial_remote_code":"8"}"#.utf8)
        let fields = try XCTUnwrap(NativeAccessibilityDiagnostic.decode(data, requestID: 2)).logFields
        XCTAssertTrue(fields.contains("axPhase=target_validation"))
        XCTAssertTrue(fields.contains("axFallbackFrom=selection_initial"))
        XCTAssertTrue(fields.contains("axInitialRemoteCode=8"))
        XCTAssertFalse(fields.contains("axRemoteCode="))
    }

    #if COREDEVICE_OFFLINE_FIXTURES
    @MainActor func testDiagnosticsCrossNativeABIWithoutChangingFailureOrBlockingNextOperation() async throws {
        let client = NativeDeveloperServices()
        try await client.connectMediaFailureFixture()
        defer { client.close() }
        var detailedFailures = 0, plainFailures = 0
        for _ in 0..<2 {
            do { try await client.accessibilityFailureFixture(); XCTFail("Expected remote refusal") }
            catch { XCTAssertEqual(error as? NativeBackendError, .accessibilityFailure(stage: 29, cause: 14)) }
            if let fields = client.lastAccessibilityDiagnostic?.logFields {
                detailedFailures += 1
                XCTAssertTrue(fields.contains("axRemoteCode=8"))
                XCTAssertTrue(fields.contains("axPhase=selection_initial"))
            } else { plainFailures += 1 }
        }
        XCTAssertEqual(detailedFailures, 1); XCTAssertEqual(plainFailures, 1)
        try await client.checkDeveloperReadiness()
        XCTAssertNil(client.lastAccessibilityDiagnostic, "A later request must not inherit old failure details")
    }
    #endif
}
