import Foundation
import CryptoKit
import OSLog

/// Bounded local history. Only explicit state fields and hashed correlation IDs are accepted;
/// RPC bodies, keys, certificates, network addresses and tool arguments never enter this log.
@MainActor final class MuseDiagnosticsLog {
    struct Event: Codable {
        let time: Date
        let uptime: TimeInterval
        let stage: String
        let diagnosticID: String?
        let client: String?
        let run: String?
        let code: String?
        let state: [String: String]
    }
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhoneAgent/Remote", isDirectory: true)
    }
    static func tag(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
    private let url: URL
    private let capacity: Int
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Actell", category: "MuseAdmission")
    private(set) var events: [Event] = []
    private(set) var storageError: String?
    init(directory: URL = MuseDiagnosticsLog.defaultDirectory, capacity: Int = 300) {
        url = directory.appendingPathComponent("muse-admission-v1.json")
        self.capacity = max(1, min(capacity, 300))
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                events = Array(try JSONDecoder().decode([Event].self, from: Data(contentsOf: url)).suffix(self.capacity))
            }
        } catch { recordStorageError(error) }
    }
    func record(_ stage: String, request: String? = nil, client: String? = nil,
                run: String? = nil, code: String? = nil, state: [String: String]) {
        let event = Event(time: Date(), uptime: ProcessInfo.processInfo.systemUptime, stage: stage,
                          diagnosticID: request.map(Self.tag), client: client.map(Self.tag),
                          run: run.map(Self.tag), code: code, state: state)
        events.append(event)
        events = Array(events.suffix(capacity))
        // OSLog is a second channel if protected storage or disk writes fail.
        logger.notice("stage=\(stage, privacy: .public) diagnostic=\(event.diagnosticID ?? "-", privacy: .public) code=\(code ?? "-", privacy: .public) state=\(String(describing: state), privacy: .public)")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var directory = url.deletingLastPathComponent()
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            try JSONEncoder().encode(events).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            storageError = nil
        } catch { recordStorageError(error) }
    }
    private func recordStorageError(_ error: Error) {
        let native = error as NSError
        storageError = "\(native.domain):\(native.code)"
        logger.error("diagnostics storage failure=\(self.storageError ?? "unknown", privacy: .public)")
    }
    func report() -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(events)) ?? Data()
        return "Muse connection and RPC history (last \(capacity) events, persists across launches)\nstorage=\(storageError ?? "ok")\n" + String(decoding: data, as: UTF8.self)
    }
}
