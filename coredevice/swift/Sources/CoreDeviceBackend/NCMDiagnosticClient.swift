// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Network

/// Short, bounded connections to S3 diagnostics, never to the phone's own
/// RemotePairing address. One command at a time; no reconnect or action replay.
@MainActor public final class NCMDiagnosticClient {
    private struct Pending {
        let id: UUID
        let connection: NWConnection
        let continuation: CheckedContinuation<DiagnosticReply, Error>
        var bytes = Data()
        var sent = false
    }
    private var pending: Pending?
    private var timer: Task<Void, Never>?
    public init() {}

    public func request(_ command: DiagnosticCommand) async throws -> DiagnosticReply {
        guard pending == nil else { throw CoreDeviceError.busy }
        try Task.checkCancellation()
        let binding = try NCMInterfaceBinding.resolve(NetworkInterfaces.inventory())
        let connection = NWConnection(host: .ipv4(binding.remoteAddress), port: 28767, using: binding.parameters())
        return try await exchange(command, connection: connection)
    }
    // Internal test seam: the public path always resolves and binds actual NCM.
    func exchange(_ command: DiagnosticCommand, connection: NWConnection, timeout: Duration = .seconds(7)) async throws -> DiagnosticReply {
        guard pending == nil else { throw CoreDeviceError.busy }
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending = Pending(id: id, connection: connection, continuation: continuation)
                connection.stateUpdateHandler = { [weak self] state in
                    // Network callbacks execute on the explicitly selected main queue.
                    Task { @MainActor [weak self] in
                        guard let self, self.pending?.id == id else { return }
                        switch state {
                        case .ready:
                            guard self.pending?.sent == false else { return }
                            self.pending?.sent = true
                            connection.send(content: Data(command.wire.utf8), completion: .contentProcessed { [weak self] error in
                                Task { @MainActor [weak self] in
                                    if error != nil { self?.finish(id, .failure(CoreDeviceError.network)) }
                                    else { self?.receive(id) }
                                }
                            })
                        case .failed: self.finish(id, .failure(CoreDeviceError.network))
                        case .cancelled: self.finish(id, .failure(CoreDeviceError.disconnected))
                        default: break
                        }
                    }
                }
                timer = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.finish(id, .failure(CoreDeviceError.timeout))
                }
                connection.start(queue: .main)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, .failure(CancellationError())) }
        }
    }
    public func cancel() {
        if let id = pending?.id { finish(id, .failure(CancellationError())) }
    }
    private func receive(_ id: UUID) {
        guard let current = pending, current.id == id else { return }
        current.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, self.pending?.id == id else { return }
                if let data { self.pending?.bytes.append(data) }
                guard let bytes = self.pending?.bytes, bytes.count <= 4096 else {
                    self.finish(id, .failure(CoreDeviceError.malformedReply)); return
                }
                if error != nil { self.finish(id, .failure(CoreDeviceError.network)) }
                else if complete { self.finish(id, Result { try DiagnosticReply.decode(bytes) }) }
                else { self.receive(id) }
            }
        }
    }
    private func finish(_ id: UUID, _ result: Result<DiagnosticReply, Error>) {
        guard let current = pending, current.id == id else { return }
        pending = nil
        timer?.cancel(); timer = nil
        current.connection.stateUpdateHandler = nil
        current.connection.cancel()
        current.continuation.resume(with: result)
    }
}
