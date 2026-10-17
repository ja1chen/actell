import CryptoKit
import Foundation

/// Authenticates the *original* HTTP body. The caller must first decode the
/// envelope strictly (including rejecting duplicate JSON keys), then pass the
/// exact envelope client_id and request_id. Never re-encode JSON for verification.
@MainActor
final class RemoteRequestAuthenticator {
    enum Failure: Error, Equatable {
        case malformed
        case unauthorized
        case expired
        case replayed
        case replayCacheFull
    }

    enum RejectionReason: String {
        case malformed, clock_skew, key_unavailable, signature_mismatch
        case replayed, cache_full, monotonic_clock_unavailable
    }
    private(set) var rejectionReason: RejectionReason?
    private func reject(_ failure: Failure, reason: RejectionReason) throws -> Never {
        rejectionReason = reason
        throw failure
    }

    private struct NonceKey: Hashable {
        let clientID: String
        let nonce: UUID
    }

    static let allowedClockSkew: TimeInterval = 60
    static let nonceLifetime: TimeInterval = 120
    static let maximumTrackedNonces = 4_096

    // Look up live key material on *every* request, so deleting/rotating a key
    // takes effect without restarting the listener. Never cache key material.
    private var keyLookup: @MainActor (String) -> Data?
    private let monotonicTime: @MainActor () -> TimeInterval
    private var nonces: [NonceKey: TimeInterval] = [:]

    init(
        keyLookup: @escaping @MainActor (String) -> Data?,
        monotonicTime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.keyLookup = keyLookup
        self.monotonicTime = monotonicTime
    }

    /// Reconfigure the live credential store without dropping replay history.
    func replaceKeyLookup(_ keyLookup: @escaping @MainActor (String) -> Data?) {
        self.keyLookup = keyLookup
    }

    /// Lowercase header names come from RemoteHTTPRequestParser. Verification
    /// and nonce insertion are synchronous on the main actor, hence atomic.
    func verify(
        clientID: String,
        requestID: String,
        headers: [String: String],
        body: Data,
        now: Date = Date()
    ) throws {
        rejectionReason = nil
        guard Self.isValidClientID(clientID), Self.isValidClientID(requestID),
              let time = headers["x-actell-time"],
              let seconds = Int64(time), seconds >= 0, String(seconds) == time,
              let nonceText = headers["x-actell-nonce"], Self.isCanonicalUUID(nonceText),
              let nonce = UUID(uuidString: nonceText),
              let signatureText = headers["x-actell-signature"],
              let signature = Self.decodeSignature(signatureText) else {
            try reject(.malformed, reason: .malformed)
        }
        let wallTime = now.timeIntervalSince1970
        guard wallTime.isFinite,
              abs(wallTime - TimeInterval(seconds)) <= Self.allowedClockSkew else {
            try reject(.expired, reason: .clock_skew)
        }
        guard let secret = keyLookup(clientID), secret.count >= 32 else {
            try reject(.unauthorized, reason: .key_unavailable)
        }
        let message = Self.signingMessage(
            clientID: clientID, requestID: requestID, time: time, nonce: nonceText, body: body
        )
        guard HMAC<SHA256>.isValidAuthenticationCode(
            signature, authenticating: message, using: SymmetricKey(data: secret)
        ) else {
            try reject(.unauthorized, reason: .signature_mismatch)
        }

        // A wall-clock adjustment must not prematurely expire replay entries.
        let tick = monotonicTime()
        guard tick.isFinite, tick >= 0 else { try reject(.unauthorized, reason: .monotonic_clock_unavailable) }
        nonces = nonces.filter { $0.value > tick }
        let nonceKey = NonceKey(clientID: clientID, nonce: nonce)
        guard nonces[nonceKey] == nil else { try reject(.replayed, reason: .replayed) }
        // Fail closed instead of evicting a still-live nonce under pressure.
        guard nonces.count < Self.maximumTrackedNonces else { try reject(.replayCacheFull, reason: .cache_full) }
        nonces[nonceKey] = tick + Self.nonceLifetime
    }

    static func isValidClientID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return !bytes.isEmpty && bytes.count <= 128 && bytes.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                || $0 == 45 || $0 == 95
        }
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        guard value.utf8.count == 36, let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value.lowercased()
    }

    /// This helper intentionally performs no JSON transformation or whitespace
    /// normalization. The newline after nonce is part of the protocol.
    static func signingMessage(
        clientID: String, requestID: String, time: String, nonce: String, body: Data
    ) -> Data {
        var message = Data("ACTELL1\n\(clientID)\n\(requestID)\n\(time)\n\(nonce)\n".utf8)
        message.append(body)
        return message
    }

    private static func decodeSignature(_ text: String) -> Data? {
        let bytes = Array(text.utf8)
        guard bytes.count == 64 else { return nil }
        func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 97...102: return byte - 87
            default: return nil
            }
        }
        var decoded = Data(capacity: 32)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else { return nil }
            decoded.append((high << 4) | low)
        }
        return decoded
    }
}
