// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CCoreDeviceBackend

/// Fixed, payload-free timings. The observer is inherited by child Tasks; spans
/// capture it explicitly before crossing decoder queues. No wall-clock subtraction.
public enum NativePerformanceTrace {
    public enum Stage: String, Sendable {
        case controlPreparation = "control_preparation", discovery, developerReadiness = "developer_readiness"
        case pairSocket = "pair_socket", pairVerify = "pair_verify", pairValidation = "pair_validation"
        case tunnelListener = "tunnel_listener", tunnelSocket = "tunnel_socket", tunnelTLS = "tunnel_tls"
        case serviceSocket = "service_socket", serviceDiscovery = "service_discovery"
        case mediaStart = "media_start", freshFrameWait = "fresh_frame_wait", originalEncoding = "original_encoding"
        case thumbnailEncoding = "thumbnail_encoding", cacheWrite = "cache_write", resultReady = "result_ready", release
    }
    public struct Sample: Sendable {
        public let stage: Stage
        public let elapsedNanoseconds: UInt64
        public let uptimeNanoseconds: UInt64
        public let succeeded: Bool
        public let bytes: Int?
    }
    @TaskLocal public static var observer: (@Sendable (Sample) -> Void)?
    public struct Span: Sendable {
        let stage: Stage
        let began = DispatchTime.now().uptimeNanoseconds
        let observer: (@Sendable (Sample) -> Void)?
        public func end(succeeded: Bool = true, bytes: Int? = nil) {
            let now = DispatchTime.now().uptimeNanoseconds
            observer?(Sample(stage: stage, elapsedNanoseconds: now - began,
                             uptimeNanoseconds: now, succeeded: succeeded, bytes: bytes))
        }
    }
    public static func begin(_ stage: Stage) -> Span { Span(stage: stage, observer: observer) }
    public static func measure<T>(_ stage: Stage, _ work: () async throws -> T) async rethrows -> T {
        let span = begin(stage)
        do { let result = try await work(); span.end(); return result }
        catch { span.end(succeeded: false); throw error }
    }
    static func recoverySample(stage: UInt32, failed: Bool, data: Data) throws {
        let stages: [Stage] = [.pairSocket, .pairVerify, .pairValidation, .tunnelListener,
                               .tunnelSocket, .tunnelTLS, .serviceSocket, .serviceDiscovery]
        guard (1...8).contains(stage), data.count == 8 else { throw NativeBackendError.malformedEvent }
        let duration = data.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
        observer?(Sample(stage: stages[Int(stage) - 1], elapsedNanoseconds: duration,
                         uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds, succeeded: !failed, bytes: nil))
    }
}

/// Existing, authorized RemotePairing identity only. No filesystem/Keychain
/// discovery, generation or conversion from a Lockdown record is performed.
public struct AuthorizedRemoteIdentity {
    public var signingSeed: Data
    public let controllerID: String
    public let peerID: String
    public let peerPublicKey: Data
    public let alternateIRK: Data
    public let peerUDID: String
    public let peerModel: String
    public init(signingSeed: Data, controllerID: String, peerID: String, peerPublicKey: Data,
                alternateIRK: Data, peerUDID: String, peerModel: String) throws {
        guard signingSeed.count == 32, peerPublicKey.count == 32, alternateIRK.count == 16,
              [controllerID, peerID, peerUDID, peerModel].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.utf8.contains(0) }) else { throw NativeBackendError.invalidIdentity }
        self.signingSeed = signingSeed; self.controllerID = controllerID; self.peerID = peerID
        self.peerPublicKey = peerPublicKey; self.alternateIRK = alternateIRK; self.peerUDID = peerUDID; self.peerModel = peerModel
    }
    /// Best-effort clearing of this owned Data value; callers must also dispose
    /// of their original copies. No claim that Swift eliminates every COW copy.
    public mutating func clearSeed() { signingSeed.resetBytes(in: signingSeed.startIndex..<signingSeed.endIndex); signingSeed.removeAll() }
}
public struct ExistingSessionAuthorization {
    public let verifyExistingIdentity: Bool
    public let screen: Bool
    public let screenVideoStream: Bool
    public let input: Bool
    public init(verifyExistingIdentity: Bool, screen: Bool = false, screenVideoStream: Bool = false, input: Bool = false) {
        self.verifyExistingIdentity = verifyExistingIdentity; self.screen = screen
        self.screenVideoStream = screenVideoStream; self.input = input
    }
    var mask: UInt32 { (screen ? 1 : 0) | (screenVideoStream ? 2 : 0) | (input ? 4 : 0) | (verifyExistingIdentity ? 8 : 0) }
}
public enum NativeBackendError: Error, Equatable {
    case invalidIdentity, authorizationRequired, unsupportedABI, invalidCandidate, busy, closed, malformedEvent
    case transport(code: Int32)
    /// Numeric protocol categories only; never raw peer data or keys.
    case protocolFailure(stage: UInt32, cause: UInt32)
    case touchPreparationFailure(stage: UInt32, cause: UInt32)
    case applicationQueryFailure(stage: UInt32, cause: UInt32)
    case screenshotFailure(stage: UInt32, cause: UInt32)
}
/// Read-only input preparation failed; no HID report has been submitted.
/// These failures do not invalidate the authenticated control session.
public struct NativeInputGeometryError: Error, Equatable, Sendable {
    public enum Reason: String, Sendable {
        case metadataQuery = "metadata_query"
        case metadataInvalid = "metadata_invalid"
        case decoderUnavailable = "decoder_unavailable"
        case decoderFailed = "decoder_failed"
        case invalidToken = "invalid_token"
        case generationChanged = "generation_changed"
        case snapshotUnavailable = "snapshot_unavailable"
        case decoderChanged = "decoder_changed"
        case streamChanged = "stream_changed"
        case sizeMismatch = "size_mismatch"
        case framePending = "frame_pending"
    }
    public let reason: Reason
    public let stage: UInt32
    public let cause: UInt32
    public init(_ reason: Reason, stage: UInt32 = 0, cause: UInt32 = 0) {
        self.reason = reason; self.stage = stage; self.cause = cause
    }
    /// Fixed categories only; no peer payload, image, coordinates or credential.
    public var diagnosticFields: [String: String] {
        ["geometry_reason": reason.rawValue, "native_stage": String(stage), "native_cause": String(cause)]
    }
}
public enum InputDelivery: Sendable { case reportsWrittenVisualEffectUnverified }

/// Owns one native worker, its two relay streams and media. The caller closes
/// on explicit stop, execution expiry or disconnect, rather than app visibility.
/// Initializer is idle and never imports credentials.
@MainActor public final class NativeDeveloperServices: DeveloperServices {
    public static var linkedABIVersion: UInt32 { coredevice_backend_abi() }
    private var handle: UInt64 = 0
    private var serial: UInt64 = 0
    private var busy = false
    private var ready = false
    private var services: [String] = []
    private var videoPollSerial: UInt64 = 0
    private var videoPump: Task<Void, Never>?
    private var videoDecoder: CoreDeviceVideoDecoder?
    public private(set) var videoSnapshotDiagnostics: String?
    private var videoDecodeFailure: NativeBackendError?
    public init() {}
    deinit { videoPump?.cancel(); if handle != 0 { coredevice_backend_close(handle) } }
    public func close() {
        videoPump?.cancel(); videoPump = nil
        videoDecoder = nil; videoDecodeFailure = nil
        let old = handle; handle = 0; ready = false; services = []
        if old != 0 { coredevice_backend_close(old) }
    }
    /// Caller must refresh discovery just before this call (candidate TTL).
    /// Bind to the actual .2/24 Ethernet interface, never default routing.
    public func connect(identity: AuthorizedRemoteIdentity, authorization: ExistingSessionAuthorization,
                        discovery: DiagnosticReply, endpoint: DiagnosticReply.Endpoint) async throws {
        try Task.checkCancellation()
        guard authorization.verifyExistingIdentity else { throw NativeBackendError.authorizationRequired }
        guard !busy, handle == 0 else { throw NativeBackendError.busy }
        guard Self.linkedABIVersion == COREDEVICE_BACKEND_ABI else { throw NativeBackendError.unsupportedABI }
        guard let generation = discovery.generation, generation > 0, endpoint.service == "remotepairing",
              discovery.endpoints?.contains(where: { $0.index == endpoint.index && $0.family == endpoint.family && $0.port == endpoint.port && $0.service == endpoint.service }) == true else { throw NativeBackendError.invalidCandidate }
        let row = try NCMInterfaceBinding.resolve(NetworkInterfaces.inventory()).row
        var config = coredevice_config(abi: 1, interface_index: row.index, generation: generation, endpoint_index: UInt32(endpoint.index), permissions: authorization.mask)
        let values = [identity.signingSeed, Data(identity.controllerID.utf8), Data(identity.peerID.utf8), identity.peerPublicKey,
                      identity.alternateIRK, Data(identity.peerUDID.utf8), Data(identity.peerModel.utf8)]
        var started: UInt64 = 0
        let code = withSlices(values) { b in
            var raw = coredevice_identity(seed: b[0], controller_id: b[1], peer_id: b[2], peer_public_key: b[3], alt_irk: b[4], peer_udid: b[5], peer_model: b[6])
            return coredevice_ncm_start(&config, &raw, &started)
        }
        guard code == 0, started != 0 else { throw NativeBackendError.transport(code: code) }
        handle = started
        try await finishConnect(started)
    }
    /// Reuses the exact authenticated CoreDevice session over a bound local VPN socket.
    public func connectLocalVPN(identity: AuthorizedRemoteIdentity, authorization: ExistingSessionAuthorization,
                                pairingPort: UInt16, configuration: VPNLoopbackConfiguration = .defaults) async throws {
        try Task.checkCancellation()
        guard authorization.verifyExistingIdentity else { throw NativeBackendError.authorizationRequired }
        guard !busy, handle == 0 else { throw NativeBackendError.busy }
        guard Self.linkedABIVersion == COREDEVICE_BACKEND_ABI else { throw NativeBackendError.unsupportedABI }
        guard pairingPort != 0 else { throw NativeBackendError.invalidCandidate }
        let row = try LocalVPNDiscovery.selectInterface(NetworkInterfaces.inventory(), configuration: configuration)
        let values = [identity.signingSeed, Data(identity.controllerID.utf8), Data(identity.peerID.utf8), identity.peerPublicKey,
                      identity.alternateIRK, Data(identity.peerUDID.utf8), Data(identity.peerModel.utf8)]
        var started: UInt64 = 0
        let code = withSlices(values) { b in
            var raw = coredevice_identity(seed: b[0], controller_id: b[1], peer_id: b[2], peer_public_key: b[3], alt_irk: b[4], peer_udid: b[5], peer_model: b[6])
            return coredevice_local_vpn_start_configured(row.index, pairingPort, authorization.mask, configuration.localIPv4, configuration.peerIPv4, &raw, &started)
        }
        guard code == 0, started != 0 else { throw NativeBackendError.transport(code: code) }
        handle = started
        try await finishConnect(started)
    }
    private func finishConnect(_ token: UInt64) async throws {
        busy = true; defer { busy = false }
        do {
            let (header, data) = try await receive(token, requestID: 0)
            guard header.kind == 1, data.count <= 256 * 1024,
                  let names = try? JSONDecoder().decode([String].self, from: data), names.count <= 4096 else { throw NativeBackendError.malformedEvent }
            services = names; ready = true
        } catch { if handle == token { close() }; throw error }
    }
    public func listServices() async throws -> [String] {
        guard ready, handle != 0 else { throw NativeBackendError.closed }; return services
    }
    public func checkDeveloperReadiness() async throws { _ = try await operation(1) }
    public func capturePNG() async throws -> Data { try await operation(2, expectedKind: 4) }
    /// Starts an authenticated screen video stream; packets are drained locally.
    public func startTouchMedia() async throws {
        _ = try await operation(3)
        videoPump?.cancel()
        let decoder = CoreDeviceVideoDecoder()
        videoDecoder = decoder; videoDecodeFailure = nil
        let token = handle
        videoPump = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let consumed: Bool
                do {
                    guard let self, self.handle == token, self.videoDecoder === decoder else { return }
                    consumed = try await self.receiveVideoPicture(token: token, decoder: decoder)
                    self.videoPollSerial &+= 1
                } catch is CancellationError { return }
                catch {
                    if let self, self.handle == token, self.videoDecoder === decoder {
                        _ = coredevice_backend_video_invalidate_geometry(token)
                        self.videoDecodeFailure = .screenshotFailure(stage: 20, cause: 1)
                    }
                    return
                }
                // Do not retain the service across the idle wait.
                if !consumed { do { try await Task.sleep(for: .milliseconds(5)) } catch { return } }
            }
        }
    }
    /// Stop local decode immediately, then release this controller's owned
    /// DisplayService/HID streams without revoking the authentication tunnel.
    public func stopTouchMedia() async throws {
        videoPump?.cancel(); videoPump = nil
        let decoder = videoDecoder; videoDecoder = nil; videoDecodeFailure = nil
        _ = try await operation(11)
        if let decoder { await decoder.reset() }
    }
    /// Snapshot the continuously decoded video picture, independent of input history.
    private var publishedDecoderGeometry: (token: String, credential: UInt64)?
    public private(set) var capturedVideoGeometryToken: String?
    /// Reads the existing decoded stream only; never requests another screenshot.
    public func validateVideoGeometry(_ expected: String) async throws {
        guard ready, handle != 0 else { throw NativeBackendError.closed }
        let token = handle
        var before = coredevice_video_snapshot()
        let snapshotStatus = coredevice_backend_video_get_snapshot(token, &before)
        if snapshotStatus == 3 { throw NativeBackendError.closed }
        guard videoDecodeFailure == nil else { throw NativeInputGeometryError(.decoderFailed) }
        guard let decoder = videoDecoder else { throw NativeInputGeometryError(.decoderUnavailable) }
        guard let separator = expected.lastIndex(of: "|"),
              let credential = UInt64(expected[expected.index(after: separator)...]), credential != 0 else { throw NativeInputGeometryError(.invalidToken) }
        let decodedGeometry = String(expected[..<separator])
        guard coredevice_backend_video_geometry_generation(token) == credential else { throw NativeInputGeometryError(.generationChanged) }
        guard snapshotStatus == 0 else { throw NativeInputGeometryError(.snapshotUnavailable) }
        let geometry = await decoder.currentGeometryToken()
        guard token == handle, ready else { throw NativeBackendError.closed }
        guard geometry == decodedGeometry else { throw NativeInputGeometryError(.decoderChanged) }
        var after = coredevice_video_snapshot()
        let afterStatus = coredevice_backend_video_get_snapshot(token, &after)
        if afterStatus == 3 { throw NativeBackendError.closed }
        guard videoDecodeFailure == nil else { throw NativeInputGeometryError(.decoderFailed) }
        guard videoDecoder === decoder else { throw NativeInputGeometryError(.decoderChanged) }
        guard afterStatus == 0,
              before.epoch == after.epoch,
              coredevice_backend_video_geometry_generation(token) == credential,
              decodedGeometry.hasPrefix("\(after.epoch):") else { throw NativeInputGeometryError(.streamChanged) }
    }
    /// Read authenticated display metadata and existing decoder geometry only.
    /// No JPEG encoding, screenshot request or image publication occurs here.
    public func inputDisplayGeometry() async throws -> String {
        let data = try await operation(12, expectedKind: 15)
        guard let size = (try? JSONSerialization.jsonObject(with: data)) as? [String: Int],
              let width = size["width"], let height = size["height"], width > 1, height > 1 else { throw NativeInputGeometryError(.metadataInvalid) }
        let handleAtStart = handle
        let until = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < until {
            try Task.checkCancellation()
            guard ready, handle != 0, handle == handleAtStart else { throw NativeBackendError.closed }
            var snapshot = coredevice_video_snapshot()
            if coredevice_backend_video_get_snapshot(handle, &snapshot) == 3 { throw NativeBackendError.closed }
            guard videoDecodeFailure == nil else { throw NativeInputGeometryError(.decoderFailed) }
            guard let decoder = videoDecoder else { throw NativeInputGeometryError(.decoderUnavailable) }
            if let published = publishedDecoderGeometry,
               published.credential == coredevice_backend_video_geometry_generation(handle),
               let token = await decoder.currentGeometryToken(), token == published.token {
                let parts = token.split(separator: ":")
                guard parts.count == 8 else { throw NativeInputGeometryError(.invalidToken) }
                guard Double(parts[6]) == Double(width), Double(parts[7]) == Double(height) else { throw NativeInputGeometryError(.sizeMismatch) }
                let result = "\(token)|\(published.credential)"
                try await validateVideoGeometry(result)
                return result
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NativeInputGeometryError(.framePending)
    }
    public func captureVideoJPEG() async throws -> Data {
        capturedVideoGeometryToken = nil
        guard ready, handle != 0, let decoder = videoDecoder else { throw NativeBackendError.closed }
        videoSnapshotDiagnostics = nil
        let token = handle, began = ContinuousClock.now
        let freshFrameWait = NativePerformanceTrace.begin(.freshFrameWait)
        var initial = coredevice_video_status()
        let initialCode = coredevice_backend_video_get_status(token, &initial)
        var initialSnapshot = coredevice_video_snapshot()
        guard coredevice_backend_video_get_snapshot(token, &initialSnapshot) == 0 else { throw NativeBackendError.closed }
        let polledAfter = videoPollSerial
        let deadline = began.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard token == handle, ready else { throw NativeBackendError.closed }
            // The single video pump owns polling and preserves the reference chain.
            // Reject cached pixels while a new generation reset is pending.
            await Task.yield()
            guard token == handle, ready else { throw NativeBackendError.closed }
            guard videoDecoder === decoder else { throw NativeBackendError.closed }
            var snapshot = coredevice_video_snapshot()
            guard coredevice_backend_video_get_snapshot(token, &snapshot) == 0 else { throw NativeBackendError.closed }
            // A new decoded picture, or a post-request report confirming that all
            // emitted packets form the already decoded picture. Picture age alone
            // says nothing about a static display; no input-history dependency.
            let confirmed = snapshot.report > initialSnapshot.report ? snapshot.serial : 0
            let published = publishedDecoderGeometry
            let geometryCredential = published?.credential ?? 0
            if videoPollSerial != polledAfter, geometryCredential != 0,
               let jpeg = try await decoder.jpeg(notBefore: began, confirmedEpoch: snapshot.epoch, confirmedSerial: confirmed, freshFrameWait: freshFrameWait) {
                guard token == handle, ready else { throw NativeBackendError.closed }
                var after = coredevice_video_snapshot()
                guard coredevice_backend_video_get_snapshot(token, &after) == 0 else { throw NativeBackendError.closed }
                if after.epoch != snapshot.epoch { continue }
                videoDecodeFailure = nil
                videoSnapshotDiagnostics = "screenshot.video received=true decoder=\(await decoder.diagnosticStatus())"
                guard let decodedGeometry = await decoder.capturedGeometryToken(),
                      geometryCredential == coredevice_backend_video_geometry_generation(token),
                      decodedGeometry == published?.token else { continue }
                capturedVideoGeometryToken = "\(decodedGeometry)|\(geometryCredential)"
                return jpeg
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        freshFrameWait.end(succeeded: false)
        var status = coredevice_video_status()
        let code = coredevice_backend_video_get_status(token, &status)
        NSLog("CoreDevice screenshot timeout status=%d datagrams=%llu rtp=%llu rejected=%llu frames=%llu discontinuities=%llu overflows=%llu refreshes=%llu sourcePort=%llu", code, status.datagrams, status.rtp, status.rejected, status.frames, status.discontinuities, status.overflows, status.refreshes, status.source_port)
        let diagnostics = "screenshot.video timeout=true datagrams=\(status.datagrams) rtp=\(status.rtp) frames=\(status.frames) refreshes=\(status.refreshes) intervalDatagrams=\(status.datagrams &- initial.datagrams) intervalFrames=\(status.frames &- initial.frames) decoder=\(await decoder.diagnosticStatus())"
        videoSnapshotDiagnostics = diagnostics
        NSLog("CoreDevice %@", diagnostics)
        if let videoDecodeFailure { throw videoDecodeFailure }
        // Historical overload is diagnostic history, not the cause of every later failure.
        let cause = code == 0 ? CoreDeviceVideoSnapshotFailure.timeoutCause(datagrams: status.datagrams, rtp: status.rtp, frames: status.frames, overflows: status.overflows, initialOverflows: initialCode == 0 ? initial.overflows : 0) : UInt32(2)
        throw NativeBackendError.screenshotFailure(stage: 20, cause: cause)
    }
    private func receiveVideoPicture(token: UInt64, decoder: CoreDeviceVideoDecoder) async throws -> Bool {
        var header = coredevice_event()
        var status = coredevice_backend_video_poll(token, &header, nil, 0)
        if status == 4 { return false }
        if status == 3 { throw NativeBackendError.closed }
        if status == 0, header.kind == 14 { await decoder.reset(); return true }
        guard status == 5, header.kind == 13, header.size >= 64, header.size <= 8 * 1024 * 1024 else {
            throw NativeBackendError.screenshotFailure(stage: 20, cause: 1)
        }
        var data = Data(count: header.size)
        status = data.withUnsafeMutableBytes { coredevice_backend_video_poll(token, &header, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        if status == 0, header.kind == 14 { await decoder.reset(); return true }
        // A newer independent picture can replace the size-probed one.
        if status == 4 || status == 5 { return false }
        if status == 3 { throw NativeBackendError.closed }
        guard status == 0, header.kind == 13, header.size >= 64, header.size <= data.count else {
            throw NativeBackendError.screenshotFailure(stage: 20, cause: 1)
        }
        if header.size < data.count { data.removeSubrange(header.size..<data.count) }
        do {
            let sample = try CoreDeviceVideoSample(data)
            let receivedCredential = coredevice_backend_video_sample_geometry(token, sample.serial, sample.epoch)
            let decoded = try await decoder.consume(data)
            guard handle == token, ready, videoDecoder === decoder else { throw NativeBackendError.closed }
            if decoded {
                videoDecodeFailure = nil
                let geometry = await decoder.currentGeometryToken()
                guard handle == token, ready, videoDecoder === decoder else { throw NativeBackendError.closed }
                if let geometry, receivedCredential != 0,
                   coredevice_backend_video_geometry_generation(token) == receivedCredential {
                    // Never attach a newly read credential to an older decoded
                    // frame. The credential came from this exact queued sample.
                    let credential = geometry == publishedDecoderGeometry?.token ? receivedCredential
                        : coredevice_backend_video_publish_geometry(token, receivedCredential)
                    if credential != 0 { publishedDecoderGeometry = (geometry, credential) }
                }
            }
        } catch {
            try Task.checkCancellation()
            guard handle == token, ready, videoDecoder === decoder else { throw NativeBackendError.closed }
            _ = coredevice_backend_video_invalidate_geometry(token)
            videoDecodeFailure = (error as? NativeBackendError) ?? .screenshotFailure(stage: 20, cause: 1)
            NSLog("CoreDevice screenshot decode failed: %@", String(describing: error))
            await decoder.reset()
            _ = coredevice_backend_video_refresh(token)
        }
        return true
    }
    #if DEBUG
    /// Explicit developer probe only; no automatic persistence or network upload.
    public func videoDiagnosticKeyframe() async -> Data? { await videoDecoder?.diagnosticKeyframe() }
    #endif
    public func tapDelivery(x: UInt16, y: UInt16, geometryToken: String? = nil) async throws -> InputDelivery {
        let credential = try inputGeometryCredential(geometryToken)
        _ = try await operation(4, x: x, y: y, expectedGeometry: credential); return .reportsWrittenVisualEffectUnverified
    }
    public func tap(x: UInt16, y: UInt16) async throws { _ = try await tapDelivery(x: x, y: y) }
    public func dragDelivery(fromX: UInt16, fromY: UInt16, toX: UInt16, toY: UInt16, durationMS: UInt16, geometryToken: String? = nil) async throws -> InputDelivery {
        guard (100...2000).contains(durationMS) else { throw NativeBackendError.malformedEvent }
        let credential = try inputGeometryCredential(geometryToken)
        _ = try await operation(6, x: fromX, y: fromY, drag: (toX, toY, durationMS), expectedGeometry: credential)
        return .reportsWrittenVisualEffectUnverified
    }
    public func home() async throws { _ = try await operation(7) }
    public func installedApplications() async throws -> Data { try await operation(8, expectedKind: 11) }
    public func launchApplication(bundleID: String, arguments: [String]) async throws {
        _ = try await operation(9, payload: JSONSerialization.data(withJSONObject: ["bundle_id": bundleID, "arguments": arguments]))
    }
    public func typeText(_ text: String) async throws {
        _ = try await operation(10, payload: JSONSerialization.data(withJSONObject: ["text": text]))
    }
    private func inputGeometryCredential(_ token: String?) throws -> UInt64? {
        guard let token else { return nil }
        // Caller checked decoder geometry and its final TTL/deadline fence.
        // Parse without another suspension; Rust revalidates at dequeue/Down.
        guard let value = token.split(separator: "|").last.flatMap({ UInt64($0) }), value != 0 else { throw NativeBackendError.malformedEvent }
        return value
    }
    private func operation(_ action: UInt32, x: UInt16 = 0, y: UInt16 = 0, expectedKind: UInt32 = 2, drag: (UInt16, UInt16, UInt16)? = nil, payload: Data? = nil, expectedGeometry: UInt64? = nil) async throws -> Data {
        guard !busy else { throw NativeBackendError.busy }
        guard ready, handle != 0 else { throw NativeBackendError.closed }
        busy = true; defer { busy = false }; let token = handle
        serial += 1; let id = serial
        do {
            try Task.checkCancellation()
            let code: Int32
            if let expectedGeometry {
                code = coredevice_backend_input_guarded(token, id, action, x, y, drag?.0 ?? 0, drag?.1 ?? 0, drag?.2 ?? 0, expectedGeometry)
            }
            else if let payload { code = withSlices([payload]) { coredevice_backend_command(token, id, action, $0[0]) } }
            else if let drag { code = coredevice_backend_drag(token, id, x, y, drag.0, drag.1, drag.2) }
            else { code = coredevice_backend_submit(token, id, action, x, y) }
            guard code == 0 else { throw NativeBackendError.transport(code: code) }
            let (header, data) = try await receive(token, requestID: id)
            guard header.kind == expectedKind else { throw NativeBackendError.malformedEvent }
            return data
        } catch {
            // Display metadata uses its own read-only service stream. A query
            // error is not a tunnel failure; Rust checks the owner again before
            // returning it. Closed sessions and malformed ABI events stay fatal.
            if action == 12, case NativeBackendError.protocolFailure(let stage, let cause) = error,
               [UInt32(10), 11].contains(stage) {
                throw NativeInputGeometryError(.metadataQuery, stage: stage, cause: cause)
            }
            // A screenshot owns a fresh, read-only service stream. Dropping that
            // stream does not revoke the authenticated tunnel or replay any input.
            // Cancellation, worker closure and malformed ABI events remain fatal.
            if action == 2, case NativeBackendError.protocolFailure(let stage, let cause) = error,
               [UInt32(9), 19, 20].contains(stage) {
                throw NativeBackendError.screenshotFailure(stage: stage, cause: cause)
            }
            if case NativeBackendError.touchPreparationFailure = error { throw error }
            if case NativeBackendError.applicationQueryFailure = error { throw error }
            if handle == token { close() }; throw error
        }
    }
    private func receive(_ token: UInt64, requestID: UInt64) async throws -> (coredevice_event, Data) {
        // Overall connect/readiness/media stages can contain multiple 15s protocol
        // steps. This bound is independent of the Rust per-stage deadlines.
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard handle == token else { throw NativeBackendError.closed }
            var event = coredevice_event(); let status = coredevice_backend_poll(token, &event, nil, 0)
            if status == 4 { try await Task.sleep(for: .milliseconds(10)); continue }
            if status == 3 { throw NativeBackendError.closed }
            var data = Data()
            if status == 5 {
                guard event.size > 0, event.size <= 64 * 1024 * 1024 else { throw NativeBackendError.malformedEvent }
                data = Data(count: event.size)
                let copied = data.withUnsafeMutableBytes { bytes in coredevice_backend_poll(token, &event, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count) }
                guard copied == 0 else { throw NativeBackendError.transport(code: copied) }
            } else if status != 0 { throw NativeBackendError.transport(code: status) }
            guard event.request_id == requestID, event.reserved == 0 else { throw NativeBackendError.malformedEvent }
            if event.kind == 16 {
                guard requestID == 0, event.stage == 0, event.cause == 0,
                      !data.isEmpty, data.count <= 128, data.count % 16 == 0 else { throw NativeBackendError.malformedEvent }
                for offset in stride(from: 0, to: data.count, by: 16) {
                    let stage = data[offset..<(offset + 4)].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
                    let failed = data[(offset + 4)..<(offset + 8)].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
                    guard stage == UInt32(offset / 16 + 1), failed <= 1 else { throw NativeBackendError.malformedEvent }
                    try NativePerformanceTrace.recoverySample(stage: stage, failed: failed == 1, data: Data(data[(offset + 8)..<(offset + 16)]))
                }
                continue
            }
            if event.kind == 10 { throw NativeBackendError.touchPreparationFailure(stage: event.stage, cause: event.cause) }
            if event.kind == 12 { throw NativeBackendError.applicationQueryFailure(stage: event.stage, cause: event.cause) }
            if event.kind == 3 { throw NativeBackendError.protocolFailure(stage: event.stage, cause: event.cause) }
            return (event, data)
        }
        throw CoreDeviceError.timeout
    }
    #if COREDEVICE_OFFLINE_FIXTURES
    /// Compiled only into the separately built host test target.
    func closeWorkerFixture() { if handle != 0 { coredevice_backend_close(handle) } }
    func connectMediaFailureFixture() async throws {
        guard !busy, handle == 0 else { throw NativeBackendError.busy }
        var started: UInt64 = 0
        let code = coredevice_test_start_media_failure(&started)
        guard code == 0 else { throw NativeBackendError.transport(code: code) }
        handle = started; try await finishConnect(started)
    }
    func connectVideoBurstFixture(_ sample: Data, continuous: Bool = true) async throws {
        guard !busy, handle == 0 else { throw NativeBackendError.busy }
        var started: UInt64 = 0
        let code = withSlices([sample]) { coredevice_test_start_video_burst($0[0], continuous ? 1 : 0, &started) }
        guard code == 0 else { throw NativeBackendError.transport(code: code) }
        handle = started; try await finishConnect(started)
    }
    func connectLoopbackFixture(port: UInt16) async throws {
        guard !busy, handle == 0 else { throw NativeBackendError.busy }
        var started: UInt64 = 0; let code = coredevice_test_start_loopback(port, &started)
        guard code == 0 else { throw NativeBackendError.transport(code: code) }
        handle = started; try await finishConnect(started)
    }
    #endif
}
private func withSlices<T>(_ data: [Data], _ index: Int = 0, _ slices: [coredevice_bytes] = [], _ body: ([coredevice_bytes]) -> T) -> T {
    if index == data.count { return body(slices) }
    return data[index].withUnsafeBytes { bytes in
        withSlices(data, index + 1, slices + [coredevice_bytes(data: bytes.bindMemory(to: UInt8.self).baseAddress, size: bytes.count)], body)
    }
}

/// Ordinary Lockdown only. Caller explicitly supplies the existing pairing plist.
/// Kept separate from the RP identity, discovery and screenshot/media API.
@MainActor public final class NativeLockdownSession {
    private var handle: UInt64 = 0
    private var ready = false
    private var busy = false
    public init() {}
    deinit { if handle != 0 { coredevice_backend_close(handle) } }
    public func close() {
        let old = handle; handle = 0; ready = false
        if old != 0 { coredevice_backend_close(old) }
    }
    public func connect(pairingRecord: Data, expectedUDID: String, authorized: Bool) async throws {
        try Task.checkCancellation()
        guard authorized else { throw NativeBackendError.authorizationRequired }
        guard !busy, handle == 0 else { throw NativeBackendError.busy }
        guard !pairingRecord.isEmpty, pairingRecord.count <= 1024 * 1024,
              !expectedUDID.isEmpty, expectedUDID.utf8.count <= 256 else { throw NativeBackendError.invalidIdentity }
        guard NativeDeveloperServices.linkedABIVersion == COREDEVICE_BACKEND_ABI else { throw NativeBackendError.unsupportedABI }
        let row = try NCMInterfaceBinding.resolve(NetworkInterfaces.inventory()).row
        var started: UInt64 = 0
        let code = withSlices([pairingRecord, Data(expectedUDID.utf8)]) { slices in
            coredevice_lockdown_start(row.index, UInt32(COREDEVICE_ALLOW_EXISTING_VERIFY), slices[0], slices[1], &started)
        }
        guard code == 0, started != 0 else { throw NativeBackendError.transport(code: code) }
        handle = started; busy = true; defer { busy = false }
        do { try await receive(started, requestID: 0); ready = true }
        catch { close(); throw error }
    }
    /// Normal cleanup sends StopSession on the same TLS channel. Cancellation or
    /// background close instead revokes transport; it cannot confirm remote stop.
    public func stop() async throws {
        guard !busy else { throw NativeBackendError.busy }
        guard ready, handle != 0 else { throw NativeBackendError.closed }
        busy = true; defer { busy = false; close() }
        let token = handle
        let code = coredevice_backend_submit(token, 1, 5, 0, 0)
        guard code == 0 else { throw NativeBackendError.transport(code: code) }
        try await receive(token, requestID: 1)
    }
    private func receive(_ token: UInt64, requestID: UInt64) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(40))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard handle == token else { throw NativeBackendError.closed }
            var event = coredevice_event()
            let status = coredevice_backend_poll(token, &event, nil, 0)
            if status == 4 { try await Task.sleep(for: .milliseconds(10)); continue }
            guard status == 0 else { throw NativeBackendError.transport(code: status) }
            guard event.request_id == requestID, event.size == 0, event.reserved == 0 else { throw NativeBackendError.malformedEvent }
            if event.kind == 3 { throw NativeBackendError.protocolFailure(stage: event.stage, cause: event.cause) }
            guard event.kind == 2 else { throw NativeBackendError.malformedEvent }
            return
        }
        throw CoreDeviceError.timeout
    }
}

// Media decoding is intentionally off MainActor. Only complete, ordered HEVC
// access units cross the ABI; no compressed packet or decoded image is persisted.
import VideoToolbox
import CoreImage
import ImageIO

struct CoreDeviceVideoSample {
    let serial: UInt64, epoch: UInt64, ageMS: UInt64, revision: UInt64
    let timestamp: UInt32, sync: Bool, width: Int, height: Int
    let visibleSize: CGSize?
    let parameters: [Data]
    let bytes: Data
    init(_ data: Data) throws {
        guard data.count >= 64, data.count <= 8 * 1024 * 1024 else { throw NativeBackendError.malformedEvent }
        var offset = 0
        func number(_ count: Int) -> UInt64 {
            defer { offset += count }
            return (0..<count).reduce(UInt64(0)) { $0 | UInt64(data[offset + $1]) << (8 * $1) }
        }
        serial = number(8); epoch = number(8); ageMS = number(8); revision = number(8)
        timestamp = UInt32(number(4)); let flags = number(4)
        sync = flags & 1 != 0; width = Int(number(4)); height = Int(number(4))
        let lengths = (0..<4).map { _ in Int(number(4)) }
        let headerSize = flags & 2 != 0 ? 72 : 64
        guard data.count >= headerSize else { throw NativeBackendError.malformedEvent }
        if flags & 2 != 0 {
            let w = Int(number(4)), h = Int(number(4))
            guard w > 0, h > 0, w <= width, h <= height, width - w < 64, height - h < 64 else { throw NativeBackendError.malformedEvent }
            visibleSize = CGSize(width: w, height: h)
        } else { visibleSize = nil }
        guard flags <= 3, serial > 0, width > 0, height > 0, width <= 16384, height <= 16384,
              width * height <= 32 * 1024 * 1024, lengths.allSatisfy({ $0 > 0 }),
              lengths.prefix(3).allSatisfy({ $0 <= 1024 * 1024 }),
              lengths.reduce(headerSize, +) == data.count else { throw NativeBackendError.malformedEvent }
        var fields: [Data] = []
        for length in lengths { fields.append(data.subdata(in: offset..<offset + length)); offset += length }
        parameters = Array(fields.prefix(3)); bytes = fields[3]
        // Validate length-prefixed NAL boundaries before CoreMedia sees bytes.
        var cursor = 0, count = 0
        while cursor < bytes.count {
            guard bytes.count - cursor >= 4 else { throw NativeBackendError.malformedEvent }
            let size = (0..<4).reduce(0) { ($0 << 8) | Int(bytes[cursor + $1]) }
            cursor += 4; count += 1
            guard size >= 2, size <= bytes.count - cursor, count <= 256 else { throw NativeBackendError.malformedEvent }
            cursor += size
        }
    }
}

private final class CoreDeviceDecodedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    private var status: OSStatus = noErr
    func store(_ value: CVPixelBuffer?, status: OSStatus) { lock.lock(); defer { lock.unlock() }; buffer = value; self.status = status }
    func error() -> OSStatus { lock.lock(); defer { lock.unlock() }; return status }
    func take() -> CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return buffer }
}

final class CoreDeviceVideoDecoder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "PhoneAgent.coredevice-video-decoder", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var revision: UInt64?, epoch: UInt64?
    #if DEBUG
    private var probeKeyframe: Data?
    func diagnosticKeyframe() async -> Data? {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: self.probeKeyframe) } }
    }
    #endif
    private var loggedGeometry: String?
    private var streamContentSize: CGSize?
    private var requiresSync = true
    private var latest: (buffer: CVPixelBuffer, rect: CGRect, received: ContinuousClock.Instant, serial: UInt64)?
    private var lastSerial: UInt64 = 0
    private var decodedCount: UInt64 = 0
    func diagnosticStatus() async -> String {
        await withCheckedContinuation { continuation in queue.async {
            let age = self.latest.map { String(describing: $0.received.duration(to: .now)) } ?? "none"
            continuation.resume(returning: "polled=\(self.lastSerial) decoded=\(self.decodedCount) latestAge=\(age) requiresSync=\(self.requiresSync)")
        } }
    }
    deinit { if let session { VTDecompressionSessionInvalidate(session) } }
    func reset() async {
        await withCheckedContinuation { continuation in
            queue.async { self.resetOnQueue(); continuation.resume() }
        }
    }
    private func resetOnQueue() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil; format = nil; revision = nil; epoch = nil
        latest = nil; encodedGeometryToken = nil; streamContentSize = nil; loggedGeometry = nil; requiresSync = true
        #if DEBUG
        probeKeyframe = nil
        #endif
    }
    @discardableResult func consume(_ data: Data) async throws -> Bool {
        let observed = ContinuousClock.now
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            queue.async {
                do { continuation.resume(returning: try self.decode(CoreDeviceVideoSample(data), observed: observed)) }
                catch { self.resetOnQueue(); continuation.resume(throwing: error) }
            }
        }
    }
    private func decode(_ sample: CoreDeviceVideoSample, observed: ContinuousClock.Instant) throws -> Bool {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard sample.serial > lastSerial else { throw NativeBackendError.malformedEvent }
        lastSerial = sample.serial
        if revision != sample.revision || epoch != sample.epoch { resetOnQueue() }
        if requiresSync && !sample.sync { return false }
        if session == nil {
            guard sample.sync else { return false }
            var description: CMVideoFormatDescription?
            let p = sample.parameters
            let result = p[0].withUnsafeBytes { vps in p[1].withUnsafeBytes { sps in p[2].withUnsafeBytes { pps in
                let pointers = [vps.bindMemory(to: UInt8.self).baseAddress!, sps.bindMemory(to: UInt8.self).baseAddress!, pps.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = p.map(\.count)
                return pointers.withUnsafeBufferPointer { pointers in sizes.withUnsafeBufferPointer { sizes in
                    CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 3,
                        parameterSetPointers: pointers.baseAddress!, parameterSetSizes: sizes.baseAddress!, nalUnitHeaderLength: 4,
                        extensions: nil, formatDescriptionOut: &description)
                }}
            }}}
            guard result == noErr, let description else { throw NativeBackendError.screenshotFailure(stage: 20, cause: 1) }
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            let presented = CMVideoFormatDescriptionGetPresentationDimensions(description, usePixelAspectRatio: false, useCleanAperture: true)
            guard (dimensions.width == sample.width && dimensions.height == sample.height) ||
                  (presented.width == CGFloat(sample.width) && presented.height == CGFloat(sample.height)) else { throw NativeBackendError.malformedEvent }
            var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { _, source, status, _, image, _, _ in
                if let source {
                    Unmanaged<CoreDeviceDecodedOutput>.fromOpaque(source).takeUnretainedValue().store(image, status: status)
                }
            }, decompressionOutputRefCon: nil)
            let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
            let created = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: description,
                decoderSpecification: nil, imageBufferAttributes: attributes, outputCallback: &callback,
                decompressionSessionOut: &session)
            NSLog("CoreDevice VT create status=%d", created)
            guard created == noErr else { throw NativeBackendError.screenshotFailure(stage: 20, cause: created == kVTInvalidSessionErr ? 13 : 14) }
            #if DEBUG
            if let session {
                var hardware: CFTypeRef?
                let queried = VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: kCFAllocatorDefault, valueOut: &hardware)
                NSLog("CoreDevice VT hardware query=%d value=%@", queried, String(describing: hardware))
            }
            #endif
            format = description; revision = sample.revision; epoch = sample.epoch
        }
        guard let session, let format else { throw NativeBackendError.malformedEvent }
        #if DEBUG
        if sample.sync {
            var annexB = Data()
            for parameter in sample.parameters { annexB.append(contentsOf: [0,0,0,1]); annexB.append(parameter) }
            let raw = [UInt8](sample.bytes); var offset = 0
            while offset < raw.count {
                let size = raw[offset..<offset+4].reduce(0) { ($0 << 8) | Int($1) }; offset += 4
                annexB.append(contentsOf: [0,0,0,1]); annexB.append(contentsOf: raw[offset..<offset+size]); offset += size
            }
            probeKeyframe = annexB
        }
        #endif
        let picture = try CoreDeviceDisplayPicture(sample.bytes, codedWidth: Int(CMVideoFormatDescriptionGetDimensions(format).width),
                                            codedHeight: Int(CMVideoFormatDescriptionGetDimensions(format).height))
        if let w = picture.visibleWidth, let h = picture.visibleHeight { streamContentSize = CGSize(width: w, height: h) }
        let pictureBytes = picture.bytes
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: pictureBytes.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: pictureBytes.count,
            flags: 0, blockBufferOut: &block) == noErr, let block else { throw NativeBackendError.malformedEvent }
        let copied = pictureBytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: pictureBytes.count) }
        guard copied == noErr else { throw NativeBackendError.malformedEvent }
        var buffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: Int64(sample.timestamp), timescale: 90000), decodeTimeStamp: .invalid)
        var size = pictureBytes.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &buffer) == noErr, let buffer else { throw NativeBackendError.malformedEvent }
        let output = CoreDeviceDecodedOutput()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: buffer, flags: [],
            frameRefcon: Unmanaged.passUnretained(output).toOpaque(), infoFlagsOut: nil)
        let waited = VTDecompressionSessionWaitForAsynchronousFrames(session)
        guard status == noErr, waited == noErr, output.error() == noErr, let pixels = output.take() else {
            NSLog("CoreDevice VT decode status=%d waited=%d callback=%d output=%d sync=%d", status, waited, output.error(), output.take() == nil ? 0 : 1, sample.sync ? 1 : 0)
            let invalid = [status, waited, output.error()].contains(kVTInvalidSessionErr)
            throw NativeBackendError.screenshotFailure(stage: 20, cause: invalid ? 13 : 14)
        }
        requiresSync = false
        decodedCount &+= 1
        // Include time in the Rust queue when deciding whether capture advanced after the request.
        let rect: CGRect
        if let size = streamContentSize ?? sample.visibleSize {
            rect = CGRect(x: 0, y: CGFloat(CVPixelBufferGetHeight(pixels)) - size.height, width: size.width, height: size.height)
            guard CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels)).contains(rect) else { throw NativeBackendError.malformedEvent }
        } else {
        rect = try CoreDeviceVideoImage.visibleRect(buffer: pixels, width: streamContentSize.map { Int($0.width) } ?? sample.width, height: streamContentSize.map { Int($0.height) } ?? sample.height,
            formatAperture: CMVideoFormatDescriptionGetCleanAperture(format, originIsAtTopLeft: true))
        }
        let encoded = CMVideoFormatDescriptionGetDimensions(format)
        let presentation = CMVideoFormatDescriptionGetPresentationDimensions(format, usePixelAspectRatio: false, useCleanAperture: true)
        let geometry = "SPS=\(sample.width)x\(sample.height) coded=\(encoded.width)x\(encoded.height) presentation=\(presentation) buffer=\(CVPixelBufferGetWidth(pixels))x\(CVPixelBufferGetHeight(pixels)) stride=\(CVPixelBufferGetBytesPerRow(pixels)) clean=\(CVImageBufferGetCleanRect(pixels)) preferred=\(String(describing: CoreDeviceVideoImage.preferredRect(buffer: pixels))) displayContent=\(String(describing: sample.visibleSize)) trailerContent=\(String(describing: streamContentSize)) selected=\(rect)"
        if loggedGeometry != geometry {
            NSLog("CoreDevice video geometry %@", geometry)
            loggedGeometry = geometry
        }
        latest = (pixels, rect, observed.advanced(by: .milliseconds(-Int64(min(sample.ageMS, UInt64(Int64.max))))), sample.serial)
        return true
    }
    private var encodedGeometryToken: String?
    private func geometryTokenOnQueue() -> String? {
        guard let latest, !requiresSync, let epoch, let revision else { return nil }
        let r = latest.rect
        return "\(epoch):\(revision):\(CVPixelBufferGetWidth(latest.buffer)):\(CVPixelBufferGetHeight(latest.buffer)):\(r.origin.x):\(r.origin.y):\(r.width):\(r.height)"
    }
    func currentGeometryToken() async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.geometryTokenOnQueue()) }
        }
    }
    func capturedGeometryToken() async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.encodedGeometryToken) }
        }
    }
    func jpeg(notBefore: ContinuousClock.Instant, confirmedEpoch: UInt64? = nil, confirmedSerial: UInt64 = 0,
              freshFrameWait: NativePerformanceTrace.Span? = nil) async throws -> Data? {
        let observer = NativePerformanceTrace.observer
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            queue.async {
                do {
                    guard let latest = self.latest, !self.requiresSync,
                          latest.received >= notBefore || (confirmedSerial > 0 && self.epoch == confirmedEpoch && latest.serial >= confirmedSerial)
                    else { continuation.resume(returning: nil); return }
                    freshFrameWait?.end()
                    let data = try NativePerformanceTrace.$observer.withValue(observer) {
                        let span = NativePerformanceTrace.begin(.originalEncoding)
                        do {
                            let data = try CoreDeviceVideoImage.jpeg(buffer: latest.buffer, rect: latest.rect, context: self.context)
                            span.end(bytes: data.count); return data
                        } catch { span.end(succeeded: false); throw error }
                    }
                    self.encodedGeometryToken = self.geometryTokenOnQueue()
                    continuation.resume(returning: data)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// Transport/assembly diagnostics; no arbitrary maximum picture age.
struct CoreDeviceVideoSnapshotFailure {
    static func timeoutCause(datagrams: UInt64, rtp: UInt64, frames: UInt64, overflows: UInt64, initialOverflows: UInt64 = 0) -> UInt32 {
        if datagrams == 0 { return 8 }
        if rtp == 0 { return 9 }
        if frames == 0 { return 10 }
        if overflows > initialOverflows { return 12 }
        return 11
    }
}

/// SW:1 screen-sharing trailers observed on the real stream. Flag 2 carries
/// a BE16 contents rectangle; flag 3 additionally carries the encoded size.
/// Parse RBSP after emulation-prevention removal: escaping spans the boundary
/// between coded slice and metadata, so the footer has no fixed EBSP length.
struct CoreDeviceDisplayPicture {
    let bytes: Data
    let visibleWidth: Int?
    let visibleHeight: Int?
    init(_ data: Data, codedWidth: Int, codedHeight: Int) throws {
        let input = [UInt8](data)
        var output = Data(), offset = 0
        var visible: (Int, Int)?
        while offset < input.count {
            guard input.count - offset >= 4 else { throw NativeBackendError.malformedEvent }
            let length = input[offset..<offset+4].reduce(0) { ($0 << 8) | Int($1) }
            offset += 4
            guard length >= 2, length <= input.count - offset else { throw NativeBackendError.malformedEvent }
            var nal = Array(input[offset..<offset+length]); offset += length
            let type = (nal[0] >> 1) & 63
            if type < 32 {
                let raw = Self.unescape(Array(nal.dropFirst(2)))
                let tailLength = raw.last == 2 ? 9 : raw.last == 3 ? 13 : 0
                if tailLength > 0, raw.count > tailLength {
                    let t = Array(raw.suffix(tailLength))
                    func pair(_ i: Int) -> Int { Int(t[i]) << 8 | Int(t[i+1]) }
                    let base = tailLength == 13 ? 4 : 0
                    let canvasMatches = base == 0 || (pair(0) == codedWidth && pair(2) == codedHeight)
                    let w = pair(base+4), h = pair(base+6)
                    if canvasMatches, pair(base) == 0, pair(base+2) == 0,
                       w > 0, h > 0, w <= codedWidth, h <= codedHeight,
                       codedWidth - w < 64, codedHeight - h < 64 {
                        if let visible, visible.0 != w || visible.1 != h { throw NativeBackendError.malformedEvent }
                        visible = (w, h)
                        nal = Array(nal.prefix(2)) + Self.escape(Array(raw.dropLast(tailLength)))
                    }
                }
            }
            let n = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: n) { output.append(contentsOf: $0) }
            output.append(contentsOf: nal)
        }
        bytes = output; visibleWidth = visible?.0; visibleHeight = visible?.1
    }
    private static func unescape(_ bytes: [UInt8]) -> [UInt8] {
        var result: [UInt8] = [], zeros = 0
        for (index, byte) in bytes.enumerated() {
            if zeros == 2, byte == 3, index+1 < bytes.count, bytes[index+1] <= 3 {
                zeros = 0; continue
            }
            result.append(byte); zeros = byte == 0 ? min(2,zeros+1) : 0
        }
        return result
    }
    private static func escape(_ bytes: [UInt8]) -> [UInt8] {
        var result: [UInt8] = [], zeros = 0
        for byte in bytes {
            if zeros == 2, byte <= 3 { result.append(3); zeros = 0 }
            result.append(byte); zeros = byte == 0 ? zeros+1 : 0
        }
        return result
    }

}

/// Crop only declared picture geometry; never infer edges from UI colors.
enum CoreDeviceVideoImage {
    static func visibleRect(buffer: CVPixelBuffer, width: Int, height: Int, formatAperture: CGRect? = nil) throws -> CGRect {
        let bounds = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let size = CGSize(width: width, height: height)
        guard width > 0, height > 0, bounds.width >= size.width, bounds.height >= size.height else { throw NativeBackendError.malformedEvent }
        func valid(_ rect: CGRect) -> Bool {
            !rect.isNull && !rect.isInfinite && !rect.isEmpty && bounds.contains(rect) &&
            rect == rect.integral && rect.width <= size.width && rect.height <= size.height
        }
        // iOS 26+ producers may provide a more precise display region than the
        // ordinary clean aperture. CoreImage's automatic aperture option also
        // gives this attachment priority; preserve its offsets in raw coordinates.
        if let preferred = preferredRect(buffer: buffer), valid(preferred) { return preferred }
        // CoreVideo clean-rectangle coordinates already use CoreImage's lower-left origin.
        let clean = CVImageBufferGetCleanRect(buffer)
        if clean != bounds, valid(clean) { return clean }
        if let aperture = formatAperture {
            let rect = CGRect(x: aperture.minX, y: bounds.height - aperture.maxY, width: aperture.width, height: aperture.height)
            if valid(rect) { return rect }
        }
        // Hardware decoders may allocate aligned buffers with padding at right/bottom.
        return CGRect(x: 0, y: bounds.height - size.height, width: size.width, height: size.height)
    }
    static func preferredRect(buffer: CVPixelBuffer) -> CGRect? {
        guard let value = CVBufferCopyAttachment(buffer, kCVImageBufferPreferredCleanApertureKey, nil),
              let aperture = value as? [String: Any],
              let width = aperture[kCVImageBufferCleanApertureWidthKey as String] as? NSNumber,
              let height = aperture[kCVImageBufferCleanApertureHeightKey as String] as? NSNumber else { return nil }
        let x = (aperture[kCVImageBufferCleanApertureHorizontalOffsetKey as String] as? NSNumber)?.doubleValue ?? 0
        let y = (aperture[kCVImageBufferCleanApertureVerticalOffsetKey as String] as? NSNumber)?.doubleValue ?? 0
        return CGRect(x: (Double(CVPixelBufferGetWidth(buffer)) - width.doubleValue) / 2 + x,
                      y: (Double(CVPixelBufferGetHeight(buffer)) - height.doubleValue) / 2 - y,
                      width: width.doubleValue, height: height.doubleValue)
    }
    static func jpeg(buffer: CVPixelBuffer, rect: CGRect, context: CIContext) throws -> Data {
        let image = CIImage(cvPixelBuffer: buffer).cropped(to: rect)
        guard let cg = context.createCGImage(image, from: rect) else { throw NativeBackendError.screenshotFailure(stage: 20, cause: 1) }
        let data = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { throw NativeBackendError.malformedEvent }
        CGImageDestinationAddImage(target, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(target) else { throw NativeBackendError.screenshotFailure(stage: 20, cause: 1) }
        return data as Data
    }
}
