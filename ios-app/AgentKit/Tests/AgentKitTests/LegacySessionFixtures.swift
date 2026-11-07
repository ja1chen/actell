import Foundation
import CryptoKit
import ProviderCore
@testable import AgentKit

/// App-owned envelope+blob format used before the inline session journal.
enum LegacySessionFixtures {
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func write(root: URL, sessionID: UUID, transactions: [SessionTransaction], missing: Set<Int> = []) throws {
        let blobs = root.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let manifest = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "sessionID": sessionID.uuidString], options: [.sortedKeys])
        try manifest.write(to: root.appendingPathComponent("manifest.json"))
        var history = Data(), revision = 0
        for (index, transaction) in transactions.enumerated() {
            let durable = try DurableTransaction(transaction, writeBlob: { data in
                let name = digest(data); try data.write(to: blobs.appendingPathComponent(name)); return name
            })
            let payload = try encoder.encode(durable), name = digest(payload)
            if !missing.contains(index) { try payload.write(to: blobs.appendingPathComponent(name)) }
            if !transaction.contextItems.isEmpty || transaction.snapshot != nil || transaction.contextHead != nil { revision += 1 }
            let recoverable = transaction.kind == .contextCompacted && transaction.snapshot != nil && transaction.contextItems.isEmpty
                && transaction.displayItems.isEmpty && transaction.removedDisplayItemIDs.isEmpty && transaction.toolClaims.isEmpty
                && transaction.toolResults.isEmpty && transaction.contextHead == nil
            var envelope: [String: Any] = ["schemaVersion": 1, "sequence": index + 1, "revision": revision,
                "transactionID": transaction.id.uuidString, "sessionID": sessionID.uuidString,
                "payloadDigest": name, "payloadSize": payload.count]
            if recoverable { envelope["recoverableCompaction"] = true }
            history.append(try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])); history.append(10)
        }
        try history.write(to: root.appendingPathComponent("history.jsonl"))
    }
}
