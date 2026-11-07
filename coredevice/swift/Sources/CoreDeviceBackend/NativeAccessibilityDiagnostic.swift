// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Optional failure metadata. Decoding failure must never replace the original AX error.
public struct NativeAccessibilityDiagnostic: Equatable, Sendable {
    public let logFields: String

    static func decode(_ data: Data, requestID: UInt64) -> Self? {
        guard !data.isEmpty, data.count <= 2048,
              let value = try? JSONDecoder().decode(Wire.self, from: data), value.version == 1,
              phases.contains(value.phase), ["hit_test", "explicit_pid"].contains(value.selection) else { return nil }
        var fields = ["axRequest": String(requestID), "axPhase": value.phase, "axSelection": value.selection,
                      "axElapsedMs": String(value.elapsed_ms), "axPhaseElapsedMs": String(value.phase_elapsed_ms)]
        if let type = value.request_type, [UInt64(1), 2, 6].contains(type) { fields["axRequestType"] = String(type) }
        if let time = value.subscription_ack_ms { fields["axSubscriptionAckMs"] = String(time) }
        if let pid = value.target_pid, (1...UInt64(Int32.max)).contains(pid) { fields["axTargetPID"] = String(pid) }
        if let pid = value.observed_pid, (1...UInt64(Int32.max)).contains(pid) { fields["axObservedPID"] = String(pid) }
        if let shape = value.error_type, shapes.contains(shape) { fields["axErrorType"] = shape }
        if let code = value.remote_code, code.utf8.count <= 21, Int64(code) != nil || UInt64(code) != nil {
            fields["axRemoteCode"] = code
        }
        if let domain = value.remote_domain, !domain.isEmpty, domain.utf8.count <= 128,
           domain.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }) {
            fields["axRemoteDomain"] = domain
        } else if value.remote_domain != nil || value.remote_domain_redacted == true { fields["axRemoteDomainRedacted"] = "true" }
        if let boolean = value.remote_boolean { fields["axRemoteBoolean"] = String(boolean) }
        if let hasResult = value.has_result { fields["axHasResult"] = String(hasResult) }
        if value.fallback_from == "selection_initial", value.initial_remote_code == "8" {
            fields["axFallbackFrom"] = "selection_initial"; fields["axInitialRemoteCode"] = "8"
        }
        return .init(logFields: fields.keys.sorted().map { "\($0)=\(fields[$0]!)" }.joined(separator: " "))
    }

    private static let phases: Set<String> = ["start", "geometry_before", "geometry_after", "discovery", "connection",
        "handshake", "version", "subscription", "selection_initial", "selection_verify", "root_initial", "root_verify", "snapshot", "normalize", "target_validation"]
    private static let shapes: Set<String> = ["null", "boolean", "integer", "real", "string", "data", "array", "object", "rect"]
    private struct Wire: Decodable {
        let version: UInt64
        let selection: String
        let phase: String
        let elapsed_ms: UInt64
        let phase_elapsed_ms: UInt64
        let request_type: UInt64?
        let subscription_ack_ms: UInt64?
        let target_pid: UInt64?
        let observed_pid: UInt64?
        let error_type: String?
        let remote_code: String?
        let remote_domain: String?
        let remote_domain_redacted: Bool?
        let remote_boolean: Bool?
        let has_result: Bool?
        let fallback_from: String?
        let initial_remote_code: String?
    }
}
