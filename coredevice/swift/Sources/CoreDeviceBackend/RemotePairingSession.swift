// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CCoreDeviceBackend

/// Versioned app-owned record. Never interpolated into logs or user messages.
public struct RemotePairRecord: Codable {
    public let version: Int
    public let seed: [UInt8]
    public let controllerID: String
    public let peerID: String
    public let peerPublicKey: [UInt8]
    public let alternateIRK: [UInt8]
    public let peerUDID: String
    public let peerModel: String
    public let committed: Bool
    public func identity() throws -> AuthorizedRemoteIdentity {
        guard version == 1 else { throw NativeBackendError.invalidIdentity }
        return try AuthorizedRemoteIdentity(signingSeed: Data(seed), controllerID: controllerID,
            peerID: peerID, peerPublicKey: Data(peerPublicKey), alternateIRK: Data(alternateIRK), peerUDID: peerUDID, peerModel: peerModel)
    }
}
public struct PairingAdvertisement: Decodable {
    public let port: UInt16
    public let identifier: String
    public let txt: [String: String]
}
public enum PairingUpdate {
    case listening(PairingAdvertisement), code(String), persisted(committed: Bool), completed
}
@MainActor public final class RemotePairingSession {
    private var handle: UInt64 = 0
    public init() {}
    deinit { if handle != 0 { coredevice_backend_close(handle) } }
    public func close() { let old = handle; handle = 0; if old != 0 { coredevice_backend_close(old) } }
    /// Storage is caller-owned. Persistence errors cancel before protocol acknowledgement.
    public func pair(authorized: Bool, persist: (RemotePairRecord) throws -> Void,
                     update: (PairingUpdate) throws -> Void) async throws {
        guard authorized else { throw NativeBackendError.authorizationRequired }
        guard handle == 0 else { throw NativeBackendError.busy }
        try Task.checkCancellation()
        var token: UInt64 = 0
        let status = coredevice_pairing_start(1, &token)
        guard status == 0, token != 0 else { throw NativeBackendError.transport(code: status) }
        handle = token; defer { if handle == token { close() } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(185))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard handle == token else { throw NativeBackendError.closed }
            var event = coredevice_event()
            let status = coredevice_backend_poll(token, &event, nil, 0)
            if status == 4 { try await Task.sleep(for: .milliseconds(20)); continue }
            if status == 3 { throw NativeBackendError.closed }
            var data = Data()
            defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
            if status == 5 {
                guard event.size > 0, event.size <= 32 * 1024 else { throw NativeBackendError.malformedEvent }
                data = Data(count: event.size)
                let copied = data.withUnsafeMutableBytes { b in coredevice_backend_poll(token, &event, b.bindMemory(to: UInt8.self).baseAddress, b.count) }
                guard copied == 0 else { throw NativeBackendError.transport(code: copied) }
            } else if status != 0 { throw NativeBackendError.transport(code: status) }
            guard event.request_id == 0, event.reserved == 0 else { throw NativeBackendError.malformedEvent }
            switch event.kind {
            case 3: throw NativeBackendError.protocolFailure(stage: event.stage, cause: event.cause)
            case 5:
                let advertisement = try JSONDecoder().decode(PairingAdvertisement.self, from: data)
                guard advertisement.port != 0, !advertisement.identifier.isEmpty, advertisement.txt["identifier"] == advertisement.identifier else { throw NativeBackendError.malformedEvent }
                try update(.listening(advertisement))
            case 6:
                guard let pin = String(data: data, encoding: .utf8), !pin.isEmpty, pin.count <= 12,
                      pin.allSatisfy({ $0.isNumber || $0 == "-" }) else { throw NativeBackendError.malformedEvent }
                try update(.code(pin))
            case 7, 8:
                let record = try JSONDecoder().decode(RemotePairRecord.self, from: data)
                var identity = try record.identity(); identity.clearSeed()
                guard record.committed == (event.kind == 8) else { throw NativeBackendError.malformedEvent }
                try persist(record)
                let ack = coredevice_pairing_ack(token, event.kind == 8 ? 2 : 1)
                guard ack == 0 else { throw NativeBackendError.transport(code: ack) }
                try update(.persisted(committed: record.committed))
            case 9: try update(.completed); return
            default: throw NativeBackendError.malformedEvent
            }
        }
        throw CoreDeviceError.timeout
    }
}
