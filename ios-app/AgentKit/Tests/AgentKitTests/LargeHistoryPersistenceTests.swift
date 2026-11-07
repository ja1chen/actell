import XCTest
import Foundation
import CryptoKit
import ProviderCore
@testable import AgentKit

final class LargeHistoryPersistenceTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testLargeTextAndMetadataAreCompleteInJSONL() throws {
        let root = try directory(), id = UUID(), store = JSONLSessionStore(root: root, sessionID: id)
        let large = String(repeating: "legacy content ", count: 20_000)
        let item = DisplayItem(role: "user", text: large, metadata: .object(["appMessage": .string(large)]))
        let input = ModelInputItem.message(role: .user, content: [.text(large)])
        let call = ModelInputItem.replay(.functionCall(.init(id: "old-call", name: "fixture", arguments: "{}")))
        let result = ModelInputItem.functionResult(callID: "old-call", output: large)
        _ = try store.appendSync(.init(sessionID: id, kind: .legacyImported, contextItems: [input, call, result], displayItems: [item]), expecting: 0)
        let reopened = JSONLSessionStore(root: root, sessionID: id)
        XCTAssertEqual(try reopened.loadContextSync(id).items, [input, call, result])
        XCTAssertEqual(try reopened.presentationSync().items.first?.text, large)
        let history = try Data(contentsOf: root.appendingPathComponent("history.jsonl"))
        let lines = history.split(separator: 10)
        XCTAssertEqual(lines.count, 2)
        let header = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(lines[0])) as? [String: Any])
        XCTAssertEqual(header["type"] as? String, "session"); XCTAssertEqual(header["schemaVersion"] as? Int, 2)
        let transaction = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(lines[1])) as? [String: Any])
        XCTAssertNotNil(transaction["transaction"])
        XCTAssertTrue(String(decoding: lines[1], as: UTF8.self).contains(large))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("blobs").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("history.index").path))
    }
    func testLegacyInlineAndConflictingOldReferencesAreRejected() throws {
        let inline = DisplayItem(role: "user", text: "old", metadata: .object(["origin": .string("legacy")]))
        let oldBytes = try JSONEncoder().encode(inline)
        let old = try JSONDecoder().decode(DurableDisplayItem.self, from: oldBytes)
        XCTAssertEqual(try old.value { _, _ in XCTFail("Old inline data needs no blob"); return Data() }, inline)
        var conflicting = try XCTUnwrap(try JSONSerialization.jsonObject(with: oldBytes) as? [String: Any])
        conflicting["metadataRef"] = ["digest": "invalid", "size": 1]
        let display = try JSONDecoder().decode(DurableDisplayItem.self, from: JSONSerialization.data(withJSONObject: conflicting))
        XCTAssertThrowsError(try display.value { _, _ in Data() }) { XCTAssertEqual($0 as? StoreError, .invalidRecord) }
    }
    func testNewInlineRecordCannotReferenceTextBlob() throws {
        let root = try directory(), id = UUID(), store = JSONLSessionStore(root: root, sessionID: id)
        _ = try store.appendSync(.init(sessionID: id, kind: .turnStarted,
            contextItems: [.message(role: .user, content: [.text("kept")])]), expecting: 0)
        let historyURL = root.appendingPathComponent("history.jsonl")
        let lines = try Data(contentsOf: historyURL).split(separator: 10)
        var outer = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(lines[1])) as? [String: Any])
        var transaction = try XCTUnwrap(outer["transaction"] as? [String: Any])
        var inputs = try XCTUnwrap(transaction["contextItems"] as? [[String: Any]])
        var content = try XCTUnwrap(inputs[0]["content"] as? [[String: Any]])
        content[0]["textRef"] = ["digest": "../invalid", "size": 1]
        inputs[0]["content"] = content; transaction["contextItems"] = inputs; outer["transaction"] = transaction
        var replacement = Data(lines[0]); replacement.append(10)
        replacement.append(try JSONSerialization.data(withJSONObject: outer, options: [.sortedKeys])); replacement.append(10)
        try replacement.write(to: historyURL)
        let reopened = JSONLSessionStore(root: root, sessionID: id)
        XCTAssertThrowsError(try reopened.loadContextSync(id)) { XCTAssertEqual($0 as? StoreError, .invalidRecord) }
        XCTAssertTrue(try reopened.presentationSync().integrityGap)
    }
    func testOptionalUsageMayBeUnknownWithoutInvalidatingText() throws {
        let root = try directory(), id = UUID(), store = JSONLSessionStore(root: root, sessionID: id)
        _ = try store.appendSync(.init(sessionID: id, kind: .turnStarted,
            contextItems: [.message(role: .user, content: [.text("retained")])]), expecting: 0)
        let historyURL = root.appendingPathComponent("history.jsonl")
        let lines = try Data(contentsOf: historyURL).split(separator: 10)
        var outer = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(lines[1])) as? [String: Any])
        var transaction = try XCTUnwrap(outer["transaction"] as? [String: Any])
        transaction["usage"] = ["promptTokens": "not-a-number"]
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try JSONSerialization.data(withJSONObject: transaction, options: options)
        outer["transaction"] = transaction
        outer["payloadDigest"] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        var replacement = Data(lines[0]); replacement.append(10)
        replacement.append(try JSONSerialization.data(withJSONObject: outer, options: options)); replacement.append(10)
        try replacement.write(to: historyURL)
        let restored = try JSONLSessionStore(root: root, sessionID: id).loadContextSync(id)
        XCTAssertEqual(restored.items, [.message(role: .user, content: [.text("retained")])]); XCTAssertTrue(restored.usage.isEmpty)
    }
    func testEscapedTransactionKeysAndNestedPunctuationCannotConfuseDigest() throws {
        let root = try directory(), id = UUID(), store = JSONLSessionStore(root: root, sessionID: id)
        let text = #"braces { [ ] } and \"quoted transaction\" and backslash \\"#
        _ = try store.appendSync(.init(sessionID: id, kind: .turnStarted,
            contextItems: [.message(role: .user, content: [.text(text)])]), expecting: 0)
        let historyURL = root.appendingPathComponent("history.jsonl")
        let lines = try Data(contentsOf: historyURL).split(separator: 10)
        let normal = String(decoding: lines[1], as: UTF8.self)
        let escaped = normal.replacingOccurrences(of: "\"transaction\":", with: "\"transact\\u0069on\":")
        XCTAssertNotEqual(escaped, normal)
        var data = Data(lines[0]); data.append(10); data.append(Data(escaped.utf8)); data.append(10)
        try data.write(to: historyURL)
        let restored = try JSONLSessionStore(root: root, sessionID: id).loadContextSync(id)
        XCTAssertEqual(restored.items, [.message(role: .user, content: [.text(text)])])
        let outer = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(lines[1])) as? [String: Any])
        let transaction = try XCTUnwrap(outer["transaction"] as? [String: Any])
        let duplicate = try JSONSerialization.data(withJSONObject: transaction, options: [.sortedKeys, .withoutEscapingSlashes])
        var duplicateLine = Data(normal.dropLast().utf8)
        duplicateLine.append(Data(",\"transact\\u0069on\":".utf8)); duplicateLine.append(duplicate); duplicateLine.append(125)
        var bad = Data(lines[0]); bad.append(10); bad.append(duplicateLine); bad.append(10); try bad.write(to: historyURL)
        XCTAssertThrowsError(try JSONLSessionStore(root: root, sessionID: id).loadContextSync(id)) { XCTAssertEqual($0 as? StoreError, .invalidRecord) }
    }
}
