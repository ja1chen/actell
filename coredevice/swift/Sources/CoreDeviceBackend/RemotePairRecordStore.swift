// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Only this app's selected file; no search/import of another app's credentials.
public struct RemotePairRecordStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
    /// Explicit local reset only. A transport failure must never delete identity.
    public func remove() throws {
        if exists { try FileManager.default.removeItem(at: url) }
    }
    public func load() throws -> RemotePairRecord {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 32 * 1024 else { throw NativeBackendError.invalidIdentity }
        let record = try PropertyListDecoder().decode(RemotePairRecord.self, from: Data(contentsOf: url))
        var identity = try record.identity(); identity.clearSeed()
        return record
    }
    public func save(_ record: RemotePairRecord) throws {
        var identity = try record.identity(); identity.clearSeed()
        if exists {
            let previous = try load()
            guard previous.controllerID == record.controllerID, previous.seed == record.seed,
                  previous.peerID == record.peerID, previous.peerPublicKey == record.peerPublicKey,
                  previous.alternateIRK == record.alternateIRK, previous.peerUDID == record.peerUDID,
                  previous.peerModel == record.peerModel, !previous.committed || record.committed else {
                throw NativeBackendError.invalidIdentity
            }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        var data = try encoder.encode(record)
        defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #endif
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
        var location = url; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try location.setResourceValues(values)
    }
}
