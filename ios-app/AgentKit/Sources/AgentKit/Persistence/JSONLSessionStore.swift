import Foundation
import CryptoKit
import Darwin
import ProviderCore

public enum StoreError: Error, Sendable, Equatable {
    case busy, wrongSession, revisionConflict, transactionConflict, invalidRecord, unsupportedSchema
    case corruptHistory, missingBlob, needsMigration, invalidPath, tooLarge, io(String)
}
public enum StoreFaultPoint: Sendable { case blob, append, synchronize, index, migrationSource, migrationHistory, migrationManifest, migrationCleanup }

/// All authoritative files live directly inside the supplied session root.
public final class JSONLSessionStore: SessionStore, @unchecked Sendable {
    public typealias FaultInjector = @Sendable (StoreFaultPoint) throws -> Void
    private let root: URL
    private let sessionID: UUID
    private let requireExistingHistory: Bool
    private var hasSeenHistory = false
    private let fault: FaultInjector?
    private let mutex = NSLock()
    private var cache: Scan?
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return e }()
    private let decoder = JSONDecoder()
    private struct Manifest: Codable { var schemaVersion = 1; var sessionID: UUID; var migrationID: UUID?; var sourceDigest: String? }
    private struct Envelope: Codable {
        var schemaVersion = 1; var sequence: Int; var revision: Int; var transactionID: UUID; var sessionID: UUID
        var payloadDigest: String; var payloadSize: Int
        var recoverableCompaction: Bool? = nil
    }
    private struct Header: Codable {
        var type = "session"; var schemaVersion = 2; var sessionID: UUID
        var migrationID: UUID? = nil; var sourceDigest: String? = nil
        var missingCompactionIDs: [UUID]? = nil
    }
    private struct InlineRecord: Codable {
        var type = "transaction"; var schemaVersion = 2; var sequence: Int; var revision: Int
        var transactionID: UUID; var sessionID: UUID; var payloadDigest: String
        var transaction: DurableTransaction; var missingCompaction: Bool? = nil
    }
    private struct Entry { var envelope: Envelope; var offset: UInt64 = 0; var length: Int = 0; var missingCompaction = false }
    private struct FileStamp: Equatable {
        var device: Int64; var inode: UInt64; var size: UInt64
        var modifiedSeconds: Int64; var modifiedNanos: Int64
        var changedSeconds: Int64; var changedNanos: Int64
    }
    private struct DisplaySlot { var sequence: Int; var order: Int; var item: DisplayItem; var finalModelOutput: Bool; var protected: Bool }
    private struct Scan {
        var entries: [Entry] = []; var ids: [UUID: Int] = [:]; var display: [UUID: DisplaySlot] = [:]; var displayOrder = 0
        var presentationMetadata: JSONValue?
        var toolImages: [UUID: [SessionImageReference]] = [:]
        var contextCount = 0
        var contextNeedsRebuild = false
        var latestSnapshotIndex: Int?
        var calls: [String: PendingToolCall] = [:]
        var callOrder: [String] = []
        var callIDsByTurn: [UUID: Set<String>] = [:]
        var usage: [ModelUsage] = []
        var lastInputTokens: Int?
        var lastInputEstimate: Int?
        var calibrationEpoch: UUID?
        var committedOffset: UInt64 = 0; var fileStamp: FileStamp?; var fileSize: UInt64 = 0; var integrityGap = false; var headerRead = false
        var missingCompactionIDs: Set<UUID> = []
        mutating func project(_ transaction: SessionTransaction, sequence: Int) {
            contextCount = transaction.snapshot?.items.count ?? (contextCount + transaction.contextItems.count)
            if transaction.snapshot != nil { latestSnapshotIndex = entries.count - 1; contextNeedsRebuild = false }
            if let epoch = transaction.snapshot?.epoch ?? transaction.contextHead?.epoch, let previous = calibrationEpoch, epoch != previous {
                lastInputTokens = nil; lastInputEstimate = nil; calibrationEpoch = nil
            }
            if transaction.kind == .modelOutput, let tokens = transaction.usage?.promptTokens, tokens >= 0,
               case .object(let metadata) = transaction.metadata, case .number(let estimate) = metadata["requestEstimateTokens"],
               estimate.isFinite, estimate >= 0, estimate < Double(Int.max),
               case .string(let value) = metadata["contextEpoch"], let epoch = UUID(uuidString: value) {
                lastInputTokens = tokens; lastInputEstimate = Int(estimate); calibrationEpoch = epoch
            }
            if let value = transaction.usage { usage.append(value) }
            if let turn = transaction.turnID {
                for item in transaction.contextItems {
                    if case .replay(.functionCall(let call)) = item {
                        let key = turn.uuidString + ":" + call.id
                        callIDsByTurn[turn, default: []].insert(call.id)
                        if calls[key] == nil { calls[key] = PendingToolCall(turnID: turn, call: call, claimed: false); callOrder.append(key) }
                    }
                }
                for id in transaction.toolClaims { let key = turn.uuidString + ":" + id; if var call = calls[key] { call.claimed = true; calls[key] = call } }
            }
            for result in transaction.toolResults {
                calls.removeValue(forKey: result.turnID.uuidString + ":" + result.callID)
                if !result.outcome.images.isEmpty {
                    let invocation = ToolInvocation(sessionID: transaction.sessionID, turnID: result.turnID,
                        call: .init(id: result.callID, name: "", arguments: "{}"))
                    toolImages[invocation.displayItemID] = result.outcome.images.map(SessionImageReference.init)
                }
            }
            if [.sessionUpdated, .presentationUpdated, .legacyImported].contains(transaction.kind), let metadata = transaction.metadata { presentationMetadata = metadata }
            for id in transaction.removedDisplayItemIDs { display.removeValue(forKey: id) }
            for original in transaction.displayItems {
                var item = original
                let protected = ![TransactionKind.sessionUpdated, .presentationUpdated, .legacyImported].contains(transaction.kind)
                if let old = display[item.id] {
                    if item.createdAt == nil { item.createdAt = old.item.createdAt }
                    if case .object(let previous) = old.item.metadata, case .object(let incoming) = item.metadata {
                        item.metadata = .object(previous.merging(incoming) { _, replacement in replacement })
                    } else if item.metadata == nil { item.metadata = old.item.metadata }
                    if old.finalModelOutput && transaction.kind == .presentationUpdated && item.role == "assistant" {
                        item.text = old.item.text; item.state = old.item.state
                    }
                    display[item.id] = DisplaySlot(sequence: old.sequence, order: old.order, item: item,
                        finalModelOutput: old.finalModelOutput || (transaction.kind == .modelOutput && item.role == "assistant" && item.state == "complete"), protected: old.protected || protected)
                } else {
                    if item.createdAt == nil { item.createdAt = transaction.createdAt }
                    display[item.id] = DisplaySlot(sequence: sequence, order: displayOrder, item: item,
                        finalModelOutput: transaction.kind == .modelOutput && item.role == "assistant" && item.state == "complete", protected: protected); displayOrder += 1
                }
            }
        }
    }
    private struct Migration: Codable { var schemaVersion = 1; var id: UUID; var source: String; var digest: String }
    private struct InlineMigration: Codable { var schemaVersion = 1; var id: UUID; var source: String; var sourceDigest: String; var sourceKind: String }
    public init(root: URL, sessionID: UUID, requireExistingHistory: Bool = false, faultInjector: FaultInjector? = nil) {
        self.root = root; self.sessionID = sessionID; self.requireExistingHistory = requireExistingHistory; self.fault = faultInjector
    }
    public func append(_ transaction: SessionTransaction, expecting revision: Int) async throws -> CommitReceipt { try appendSync(transaction, expecting: revision) }
    public func readPage(_ query: HistoryQuery) async throws -> HistoryPage { try readPageSync(query) }
    public func loadContext(_ sessionID: UUID) async throws -> RestoredContext { try loadContextSync(sessionID) }
    public func readTransactions(_ sessionID: UUID) async throws -> [SessionTransaction] { try readTransactionsSync(sessionID) }
    public func readContextFacts(_ sessionID: UUID) async throws -> [SessionTransaction] { try readContextFactsSync(sessionID) }
    public func appendSync(_ transaction: SessionTransaction, expecting revision: Int) throws -> CommitReceipt {
        try locked {
            guard transaction.sessionID == sessionID else { throw StoreError.wrongSession }
            try ensureHeaderForAppend()
            return try appendLocked(transaction, expecting: revision)
        }
    }
    /// Presentation/metadata commits do not change the model context; obtain
    /// the current revision while holding the same lock as the append.
    public func appendPresentationSync(_ transaction: SessionTransaction) throws -> CommitReceipt {
        try locked {
            guard transaction.sessionID == sessionID else { throw StoreError.wrongSession }
            guard [.sessionUpdated, .presentationUpdated].contains(transaction.kind), transaction.contextItems.isEmpty,
                  transaction.snapshot == nil, transaction.contextHead == nil, transaction.toolClaims.isEmpty, transaction.toolResults.isEmpty else { throw StoreError.invalidRecord }
            try ensureHeaderForAppend()
            let scan = try scanLocked()
            let revision = scan.entries.last?.envelope.revision ?? 0
            var safe = transaction
            safe.removedDisplayItemIDs.removeAll { scan.display[$0]?.protected == true }
            return try appendLocked(safe, expecting: revision)
        }
    }
    public func readPageSync(_ query: HistoryQuery) throws -> HistoryPage {
        try locked {
            guard query.sessionID == sessionID else { throw StoreError.wrongSession }
            let scan = try scanLocked(allowPartial: true); let limit = max(1, min(query.limit, 1000))
            // Keep creation order and stable identities while applying later UI
            // updates/removals, independent of the model context revision.
            let grouped = Dictionary(grouping: scan.display.values.filter { $0.sequence < (query.beforeSequence ?? Int.max) }, by: { $0.sequence })
            let sequences = grouped.keys.sorted(); let chosen = Array(sequences.suffix(limit))
            let selected = chosen.flatMap { sequence in (grouped[sequence] ?? []).sorted { $0.order < $1.order }.map(\.item) }
            return HistoryPage(items: selected, nextBeforeSequence: sequences.count > chosen.count ? chosen.first : nil, integrityGap: scan.integrityGap)
        }
    }
    /// App list/UI state without decoding full context blobs on every update.
    public func presentationSync() throws -> SessionPresentation {
        try locked {
            let scan = try scanLocked(allowPartial: true)
            let items = scan.display.values.sorted { $0.order < $1.order }.map(\.item)
            return SessionPresentation(metadata: scan.presentationMetadata, items: items,
                sequence: scan.entries.last?.envelope.sequence ?? 0, revision: scan.entries.last?.envelope.revision ?? 0, integrityGap: scan.integrityGap,
                recoveredTail: scan.committedOffset < scan.fileSize && !scan.integrityGap,
                protectedDisplayItemIDs: Set(scan.display.values.filter(\.protected).map { $0.item.id }), toolImages: scan.toolImages)
        }
    }
    public func loadContextSync(_ id: UUID) throws -> RestoredContext {
        try locked {
            guard id == sessionID else { throw StoreError.wrongSession }
            let scan = try scanLocked()
            var items: [ModelInputItem] = [], snapshot: ContextSnapshot?
            var recoveredCompactionMissing = false
            for entry in scan.entries.dropFirst(scan.latestSnapshotIndex ?? 0) {
                if entry.missingCompaction {
                    recoveredCompactionMissing = true
                    if let old = snapshot { snapshot = ContextSnapshot(epoch: entry.envelope.transactionID, scope: old.scope, items: items, preservedNativeItemCount: old.preservedNativeItemCount) }
                    continue
                }
                let t = try readTransaction(entry)
                if let s = t.snapshot { snapshot = s; items = s.items; recoveredCompactionMissing = false } else { items += t.contextItems }
                if let head = t.contextHead, !recoveredCompactionMissing {
                    guard head.coveredItemCount >= 0 && head.coveredItemCount <= items.count else { throw StoreError.corruptHistory }
                    snapshot = ContextSnapshot(epoch: head.epoch, scope: head.scope, items: items, head: head.responseID, headCoveredItemCount: head.coveredItemCount, preservedNativeItemCount: snapshot?.preservedNativeItemCount ?? 0)
                }
            }
            return RestoredContext(revision: scan.entries.last?.envelope.revision ?? 0, sequence: scan.entries.last?.envelope.sequence ?? 0,
                snapshot: snapshot, items: items, pendingCalls: scan.callOrder.compactMap { scan.calls[$0] }, callIDsByTurn: scan.callIDsByTurn, recoveredCompactionMissing: recoveredCompactionMissing, lastInputTokens: scan.lastInputTokens, lastInputEstimate: scan.lastInputEstimate, calibrationEpoch: scan.calibrationEpoch, usage: scan.usage)
        }
    }
    public func readTransactionsSync(_ id: UUID) throws -> [SessionTransaction] {
        try locked {
            guard id == sessionID else { throw StoreError.wrongSession }
            return try scanLocked().entries.map { try readTransaction($0) }
        }
    }
    /// Portable reconstruction may ignore only a missing snapshot-only
    /// compaction candidate. Complete audit reads stay strict about that gap.
    public func readContextFactsSync(_ id: UUID) throws -> [SessionTransaction] {
        try locked {
            guard id == sessionID else { throw StoreError.wrongSession }
            var facts: [SessionTransaction] = []
            for entry in try scanLocked().entries {
                do { facts.append(try readTransaction(entry)) }
                catch StoreError.missingBlob where entry.envelope.recoverableCompaction == true { continue }
            }
            return facts
        }
    }
    /// Converts only an existing old session. New and absent histories are no-ops.
    /// The old source remains available until a fully verified replacement commits.
    public func migrateLegacySync(_ convert: (Data) throws -> [SessionTransaction]) throws {
        try locked {
            let history = root.appendingPathComponent("history.jsonl")
            let stateURL = root.appendingPathComponent(".inline-migration.json")
            if FileManager.default.fileExists(atPath: history.path), let header = try inlineHeader(at: history) {
                guard header.sessionID == sessionID else { throw StoreError.wrongSession }
                hasSeenHistory = true
                if let state = try? readInlineMigration(stateURL), header.migrationID == state.id {
                    // A previously cached scan cannot establish that images
                    // still exist before removing the only old source.
                    cache = nil
                    if (try? scanLocked()) != nil { try? cleanupInlineMigration(state, stateURL: stateURL) }
                }
                else if !FileManager.default.fileExists(atPath: stateURL.path),
                        !FileManager.default.fileExists(atPath: root.appendingPathComponent(".migration.json").path),
                        ["manifest.json", "history.index", "metadata.json", "blobs"].contains(where: { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }) {
                    cache = nil
                    if (try? scanLocked()) != nil { try? removeOldAuxiliaryFiles() }
                }
                return
            }
            let oldStateURL = root.appendingPathComponent(".migration.json")
            if !FileManager.default.fileExists(atPath: history.path), !FileManager.default.fileExists(atPath: stateURL.path), !FileManager.default.fileExists(atPath: oldStateURL.path) {
                if requireExistingHistory || hasSeenHistory { throw StoreError.corruptHistory }
                return
            }
            let state: InlineMigration
            if FileManager.default.fileExists(atPath: stateURL.path) {
                state = try readInlineMigration(stateURL)
            } else {
                let manifest = root.appendingPathComponent("manifest.json")
                var source = history, kind = "ui"
                if FileManager.default.fileExists(atPath: manifest.path) {
                    try validateLegacyManifest(); kind = "envelope"
                } else if FileManager.default.fileExists(atPath: oldStateURL.path) {
                    let old = try readOldMigration(oldStateURL)
                    let oldCopy = root.appendingPathComponent(old.source)
                    if FileManager.default.fileExists(atPath: oldCopy.path) { source = oldCopy }
                    else if try digestFile(history) != old.digest { throw StoreError.corruptHistory }
                }
                try requireSafe(source, allowMissing: false)
                let digest = try digestFile(source)
                if source != history {
                    let old = try readOldMigration(oldStateURL)
                    guard digest == old.digest else { throw StoreError.corruptHistory }
                }
                state = InlineMigration(id: UUID(), source: source.lastPathComponent, sourceDigest: digest, sourceKind: kind)
                try encoder.encode(state).write(to: stateURL, options: [.atomic, .completeFileProtection])
                try syncFile(stateURL); try syncDirectory(root)
            }
            let backup = root.appendingPathComponent(".inline-\(state.id.uuidString).source")
            let candidate = root.appendingPathComponent(".inline-\(state.id.uuidString).tmp")
            if !FileManager.default.fileExists(atPath: backup.path) {
                let source = root.appendingPathComponent(state.source)
                try requireSafe(source, allowMissing: false)
                guard try digestFile(source) == state.sourceDigest else { throw StoreError.corruptHistory }
                try fault?(.migrationSource)
                if link(source.path, backup.path) != 0 { try FileManager.default.copyItem(at: source, to: backup) }
                try syncFile(backup); try syncDirectory(root)
            }
            try requireSafe(backup, allowMissing: false)
            guard try digestFile(backup) == state.sourceDigest else { throw StoreError.corruptHistory }
            let legacy = state.sourceKind == "envelope" ? try legacyEntries(backup) : []
            let gaps = legacy.filter(\.missing).map { $0.envelope.transactionID }
            let header = Header(sessionID: sessionID, migrationID: state.id, sourceDigest: state.sourceDigest, missingCompactionIDs: gaps.isEmpty ? nil : gaps)
            let headerBytes = try encoder.encode(header)
            guard headerBytes.count + 1 <= 64 * 1024 else { throw StoreError.tooLarge }
            if FileManager.default.fileExists(atPath: candidate.path) { try requireSafe(candidate, allowMissing: false); try FileManager.default.removeItem(at: candidate) }
            guard FileManager.default.createFile(atPath: candidate.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete]) else { throw StoreError.io("create migration") }
            let output = try FileHandle(forWritingTo: candidate)
            do {
                var head = headerBytes; head.append(10); try output.write(contentsOf: head)
                if state.sourceKind == "envelope" {
                    for item in legacy {
                        let transaction = item.missing ? SessionTransaction(id: item.envelope.transactionID, sessionID: sessionID, kind: .recovery) : try readLegacyTransaction(item.envelope)
                        try writeInline(transaction, sequence: item.envelope.sequence, revision: item.envelope.revision, missing: item.missing, to: output)
                    }
                } else {
                    let source = try Data(contentsOf: backup)
                    let transactions = try convert(source)
                    guard !transactions.isEmpty, transactions.allSatisfy({ $0.sessionID == sessionID }), Set(transactions.map(\.id)).count == transactions.count else { throw StoreError.invalidRecord }
                    var revision = 0, count = 0
                    for (index, transaction) in transactions.enumerated() {
                        try validateContextTransition(transaction, currentCount: count)
                        count = transaction.snapshot?.items.count ?? (count + transaction.contextItems.count)
                        if !transaction.contextItems.isEmpty || transaction.snapshot != nil || transaction.contextHead != nil { revision += 1 }
                        try writeInline(transaction, sequence: index + 1, revision: revision, missing: false, to: output)
                    }
                }
                try output.synchronize(); try output.close()
            } catch { try? output.close(); throw error }
            let verified = try scanLocked(candidate: candidate)
            guard verified.committedOffset == verified.fileSize else { throw StoreError.corruptHistory }
            try fault?(.migrationHistory)
            guard rename(candidate.path, history.path) == 0 else { throw StoreError.io("publish migration") }
            try syncDirectory(root); cache = nil
            try fault?(.migrationManifest)
            _ = try scanLocked()
            try? cleanupInlineMigration(state, stateURL: stateURL)
        }
    }
    private func readInlineMigration(_ url: URL) throws -> InlineMigration {
        try requireSafe(url, allowMissing: false)
        let state = try decoder.decode(InlineMigration.self, from: Data(contentsOf: url))
        let sourceValid = state.source == "history.jsonl" || (state.source.hasPrefix(".migration-") && state.source.hasSuffix(".source") && !state.source.contains("/"))
        guard state.schemaVersion == 1, sourceValid, ["ui", "envelope"].contains(state.sourceKind), isDigest(state.sourceDigest) else { throw StoreError.invalidRecord }
        return state
    }
    private func readOldMigration(_ url: URL) throws -> Migration {
        try requireSafe(url, allowMissing: false)
        let state = try decoder.decode(Migration.self, from: Data(contentsOf: url))
        guard state.schemaVersion == 1, state.source == ".migration-\(state.id.uuidString).source", isDigest(state.digest) else { throw StoreError.invalidRecord }
        return state
    }
    private func cleanupInlineMigration(_ state: InlineMigration, stateURL: URL) throws {
        try fault?(.migrationCleanup)
        // Remove only the known obsolete representation after the new history
        // and every referenced image have been verified.
        try removeOldAuxiliaryFiles()
        let oldState = root.appendingPathComponent(".migration.json")
        if FileManager.default.fileExists(atPath: oldState.path) {
            let old = try readOldMigration(oldState)
            let oldSource = root.appendingPathComponent(old.source)
            if FileManager.default.fileExists(atPath: oldSource.path) { try requireSafe(oldSource, allowMissing: false); try FileManager.default.removeItem(at: oldSource) }
            try FileManager.default.removeItem(at: oldState)
        }
        for name in [".inline-\(state.id.uuidString).source", ".inline-\(state.id.uuidString).tmp"] {
            let url = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try requireSafe(url, allowMissing: false); try FileManager.default.removeItem(at: url) }
        }
        try syncDirectory(root); try FileManager.default.removeItem(at: stateURL); try syncDirectory(root)
    }
    private func removeOldAuxiliaryFiles() throws {
        for name in ["manifest.json", "history.index", "metadata.json", "blobs"] {
            let url = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try requireSafe(url, allowMissing: false); try FileManager.default.removeItem(at: url) }
        }
    }
    private static let maximumRecordBytes = 256 * 1024 * 1024
    private struct StopPartialScan: Error {}
    private struct LegacyEntry { var envelope: Envelope; var missing: Bool }

    private func appendLocked(_ transaction: SessionTransaction, expecting revision: Int) throws -> CommitReceipt {
        try validateImages(transaction)
        var scan = try scanLocked()
        let durable = try DurableTransaction(transaction, inline: true, writeBlob: storeImage)
        let payload = try encoder.encode(durable)
        let digest = Self.digest(payload)
        if let index = scan.ids[transaction.id] {
            let existing = scan.entries[index]
            guard existing.envelope.payloadDigest == digest else { throw StoreError.transactionConflict }
            try syncFile(root.appendingPathComponent("history.jsonl"))
            return CommitReceipt(sequence: existing.envelope.sequence, revision: existing.envelope.revision)
        }
        if scan.contextNeedsRebuild && transaction.contextHead != nil && transaction.snapshot == nil { throw StoreError.invalidRecord }
        try validateContextTransition(transaction, currentCount: scan.contextCount)
        let last = scan.entries.last?.envelope
        guard (last?.revision ?? 0) == revision else { throw StoreError.revisionConflict }
        let changesContext = !transaction.contextItems.isEmpty || transaction.snapshot != nil || transaction.contextHead != nil
        let sequence = (last?.sequence ?? 0) + 1, newRevision = revision + (changesContext ? 1 : 0)
        let record = InlineRecord(sequence: sequence, revision: newRevision, transactionID: transaction.id, sessionID: sessionID, payloadDigest: digest, transaction: durable)
        var line = try encoder.encode(record); guard line.count <= Self.maximumRecordBytes else { throw StoreError.tooLarge }; line.append(10)
        let url = root.appendingPathComponent("history.jsonl")
        try requireSafe(url, allowMissing: false)
        let h = try FileHandle(forUpdating: url); defer { try? h.close() }
        try h.truncate(atOffset: scan.committedOffset); try h.seek(toOffset: scan.committedOffset)
        do { try fault?(.append); try h.write(contentsOf: line); try fault?(.synchronize); try h.synchronize() }
        catch { cache = nil; throw error }
        let envelope = Envelope(sequence: sequence, revision: newRevision, transactionID: transaction.id, sessionID: sessionID, payloadDigest: digest, payloadSize: payload.count)
        cache = nil; scan.ids[transaction.id] = scan.entries.count
        scan.entries.append(Entry(envelope: envelope, offset: scan.committedOffset, length: line.count))
        scan.project(transaction, sequence: sequence); scan.committedOffset += UInt64(line.count); scan.fileSize = scan.committedOffset
        scan.fileStamp = try fileIdentity(url); cache = scan; hasSeenHistory = true
        return CommitReceipt(sequence: sequence, revision: newRevision)
    }

    private func scanLocked(allowPartial: Bool = false, candidate: URL? = nil) throws -> Scan {
        let url = candidate ?? root.appendingPathComponent("history.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else {
            if candidate != nil || requireExistingHistory || hasSeenHistory || FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path) { throw StoreError.corruptHistory }
            cache = nil; return Scan()
        }
        try requireSafe(url, allowMissing: false)
        let stamp = try fileIdentity(url), size = stamp.size
        var scan = candidate == nil ? (cache.flatMap { $0.fileStamp == stamp ? $0 : nil } ?? Scan()) : Scan()
        if candidate == nil { cache = nil }
        scan.fileStamp = stamp
        do {
            try forEachLine(url, startingAt: scan.committedOffset, limit: Self.maximumRecordBytes) { line, offset, length in
                do {
                    if !scan.headerRead {
                        guard line.count + 1 <= 64 * 1024 else { throw StoreError.tooLarge }
                        let header: Header
                        do { header = try decoder.decode(Header.self, from: line) }
                        catch { throw StoreError.needsMigration }
                        guard header.type == "session", header.schemaVersion == 2 else { throw StoreError.unsupportedSchema }
                        guard header.sessionID == sessionID else { throw StoreError.wrongSession }
                        let gaps = header.missingCompactionIDs ?? []
                        guard Set(gaps).count == gaps.count, gaps.isEmpty || (header.migrationID != nil && header.sourceDigest.map(isDigest) == true) else { throw StoreError.invalidRecord }
                        scan.missingCompactionIDs = Set(gaps); scan.headerRead = true
                        scan.committedOffset = offset + UInt64(length)
                        return
                    }
                    let record: InlineRecord
                    do { record = try decoder.decode(InlineRecord.self, from: line) } catch { throw StoreError.corruptHistory }
                    guard record.type == "transaction", record.schemaVersion == 2 else { throw StoreError.unsupportedSchema }
                    let previous = scan.entries.last?.envelope
                    guard record.sessionID == sessionID, record.sequence == (previous?.sequence ?? 0) + 1,
                          scan.ids[record.transactionID] == nil else { throw StoreError.corruptHistory }
                    let transaction = try decodeInline(record, line: line)
                    let missing = record.missingCompaction == true
                    if missing {
                        guard scan.missingCompactionIDs.contains(record.transactionID), transaction.kind == .recovery,
                              transaction.contextItems.isEmpty, transaction.displayItems.isEmpty, transaction.snapshot == nil,
                              transaction.contextHead == nil, transaction.toolClaims.isEmpty, transaction.toolResults.isEmpty,
                              transaction.metadata == nil, transaction.removedDisplayItemIDs.isEmpty else { throw StoreError.invalidRecord }
                    } else if scan.missingCompactionIDs.contains(record.transactionID) { throw StoreError.invalidRecord }
                    try validateContextTransition(transaction, currentCount: scan.contextCount, ignoreHead: scan.contextNeedsRebuild)
                    let expected = (previous?.revision ?? 0) + ((missing || !transaction.contextItems.isEmpty || transaction.snapshot != nil || transaction.contextHead != nil) ? 1 : 0)
                    guard record.revision == expected else { throw StoreError.corruptHistory }
                    let envelope = Envelope(sequence: record.sequence, revision: record.revision, transactionID: record.transactionID,
                        sessionID: record.sessionID, payloadDigest: record.payloadDigest, payloadSize: line.count, recoverableCompaction: missing ? true : nil)
                    scan.ids[record.transactionID] = scan.entries.count
                    if missing { scan.contextNeedsRebuild = true }
                    scan.entries.append(Entry(envelope: envelope, offset: offset, length: length, missingCompaction: missing))
                    scan.project(transaction, sequence: record.sequence); scan.committedOffset = offset + UInt64(length)
                } catch {
                    guard allowPartial, scan.headerRead, let failure = error as? StoreError else { throw error }
                    switch failure { case .corruptHistory, .unsupportedSchema, .invalidRecord, .missingBlob, .invalidPath, .tooLarge: break; default: throw error }
                    scan.integrityGap = true; throw StopPartialScan()
                }
            }
        } catch is StopPartialScan { }
        catch StoreError.tooLarge where allowPartial && scan.headerRead { scan.integrityGap = true }
        guard scan.headerRead else { throw StoreError.needsMigration }
        let recordedGaps = Set(scan.entries.filter(\.missingCompaction).map { $0.envelope.transactionID })
        if !scan.missingCompactionIDs.isSubset(of: recordedGaps) {
            guard allowPartial else { throw StoreError.corruptHistory }
            scan.integrityGap = true
        }
        scan.fileSize = size
        if candidate == nil { cache = scan.integrityGap ? nil : scan; hasSeenHistory = true }
        return scan
    }

    private func decodeInline(_ record: InlineRecord, line: Data) throws -> SessionTransaction {
        guard isDigest(record.payloadDigest) else { throw StoreError.invalidRecord }
        try record.transaction.requireInlineFields()
        guard try rawTransactionDigest(line) == record.payloadDigest else { throw StoreError.corruptHistory }
        let transaction = try record.transaction.value(readBlob: readImage)
        guard transaction.id == record.transactionID, transaction.sessionID == sessionID else { throw StoreError.corruptHistory }
        try validateImages(transaction)
        return transaction
    }
    private func readTransaction(_ entry: Entry) throws -> SessionTransaction {
        if entry.missingCompaction { throw StoreError.missingBlob }
        let file = root.appendingPathComponent("history.jsonl")
        try requireSafe(file, allowMissing: false)
        let h = try FileHandle(forReadingFrom: file); defer { try? h.close() }
        try h.seek(toOffset: entry.offset)
        var line = Data()
        while line.count < entry.length {
            guard let chunk = try h.read(upToCount: entry.length - line.count), !chunk.isEmpty else { throw StoreError.corruptHistory }
            line.append(chunk)
        }
        guard line.last == 10 else { throw StoreError.corruptHistory }
        let record: InlineRecord
        do { record = try decoder.decode(InlineRecord.self, from: line.dropLast()) } catch { throw StoreError.corruptHistory }
        guard record.type == "transaction", record.schemaVersion == 2, record.sequence == entry.envelope.sequence,
              record.revision == entry.envelope.revision, record.transactionID == entry.envelope.transactionID,
              record.sessionID == sessionID, record.payloadDigest == entry.envelope.payloadDigest else { throw StoreError.corruptHistory }
        return try decodeInline(record, line: Data(line.dropLast()))
    }
    private func writeInline(_ transaction: SessionTransaction, sequence: Int, revision: Int, missing: Bool, to handle: FileHandle) throws {
        try validateImages(transaction)
        let durable = try DurableTransaction(transaction, inline: true, writeBlob: storeImage)
        let digest = Self.digest(try encoder.encode(durable))
        let record = InlineRecord(sequence: sequence, revision: revision, transactionID: transaction.id, sessionID: sessionID, payloadDigest: digest, transaction: durable, missingCompaction: missing ? true : nil)
        var bytes = try encoder.encode(record); guard bytes.count <= Self.maximumRecordBytes else { throw StoreError.tooLarge }; bytes.append(10)
        try handle.write(contentsOf: bytes)
    }
    private func inlineHeader(at url: URL) throws -> Header? {
        try requireSafe(url, allowMissing: false)
        let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
        let prefix = try h.read(upToCount: 64 * 1024) ?? Data()
        guard let end = prefix.firstIndex(of: 10) else { return nil }
        let line = Data(prefix[..<end])
        guard let header = try? decoder.decode(Header.self, from: line), header.type == "session" else { return nil }
        guard header.schemaVersion == 2 else { throw StoreError.unsupportedSchema }
        return header
    }
    private func ensureHeaderForAppend() throws {
        let url = root.appendingPathComponent("history.jsonl")
        if FileManager.default.fileExists(atPath: url.path) {
            try requireSafe(url, allowMissing: false)
            if let header = try inlineHeader(at: url) { guard header.sessionID == sessionID else { throw StoreError.wrongSession }; hasSeenHistory = true; return }
            guard try fileIdentity(url).size == 0, !requireExistingHistory, !hasSeenHistory else { throw StoreError.needsMigration }
        } else if requireExistingHistory || hasSeenHistory || FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path) { throw StoreError.corruptHistory }
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent(".inline-migration.json").path),
              !FileManager.default.fileExists(atPath: root.appendingPathComponent(".migration.json").path) else { throw StoreError.needsMigration }
        var data = try encoder.encode(Header(sessionID: sessionID)); data.append(10)
        try data.write(to: url, options: [.atomic, .completeFileProtection]); try syncFile(url); try syncDirectory(root)
        cache = nil; hasSeenHistory = true
    }

    private func storeImage(_ data: Data) throws -> String {
        guard data.count <= 64 * 1024 * 1024 else { throw StoreError.tooLarge }
        let digest = Self.digest(data), dir = root.appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        try requireSafe(dir, allowMissing: false)
        let url = dir.appendingPathComponent(digest)
        if FileManager.default.fileExists(atPath: url.path) { _ = try readImage(digest, data.count); return digest }
        try fault?(.blob); try data.write(to: url, options: [.atomic, .completeFileProtection]); try syncFile(url); try syncDirectory(dir)
        return digest
    }
    private func readImage(_ digest: String, _ size: Int) throws -> Data {
        try readDigest(digest, size: size, directory: "attachments")
    }
    private func readLegacyBlob(_ digest: String, _ size: Int) throws -> Data {
        try readDigest(digest, size: size, directory: "blobs")
    }
    private func readDigest(_ digest: String, size: Int, directory: String) throws -> Data {
        guard isDigest(digest), size >= 0, size <= 64 * 1024 * 1024 else { throw StoreError.invalidRecord }
        let dir = root.appendingPathComponent(directory, isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { throw StoreError.missingBlob }
        try requireSafe(dir, allowMissing: false)
        let url = dir.appendingPathComponent(digest); guard FileManager.default.fileExists(atPath: url.path) else { throw StoreError.missingBlob }
        try requireSafe(url, allowMissing: false)
        let data = try Data(contentsOf: url); guard data.count == size, Self.digest(data) == digest else { throw StoreError.corruptHistory }; return data
    }
    private func validateLegacyManifest() throws {
        let url = root.appendingPathComponent("manifest.json"); try requireSafe(url, allowMissing: false)
        let manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: url))
        guard manifest.schemaVersion == 1 else { throw StoreError.unsupportedSchema }; guard manifest.sessionID == sessionID else { throw StoreError.wrongSession }
    }
    private func readLegacyTransaction(_ envelope: Envelope) throws -> SessionTransaction {
        let payload = try readLegacyBlob(envelope.payloadDigest, envelope.payloadSize)
        let transaction: SessionTransaction
        do { transaction = try decoder.decode(DurableTransaction.self, from: payload).value(readBlob: readLegacyBlob) }
        catch let error as StoreError { throw error } catch { throw StoreError.corruptHistory }
        guard transaction.id == envelope.transactionID, transaction.sessionID == sessionID else { throw StoreError.corruptHistory }
        try validateImages(transaction); return transaction
    }
    private func legacyEntries(_ url: URL) throws -> [LegacyEntry] {
        var entries: [LegacyEntry] = [], seen = Set<UUID>(), revision = 0, count = 0, rebuilding = false
        try forEachLine(url, startingAt: 0, limit: 8 * 1024 * 1024) { line, _, _ in
            let envelope: Envelope
            do { envelope = try decoder.decode(Envelope.self, from: line) } catch { throw StoreError.corruptHistory }
            guard envelope.schemaVersion == 1 else { throw StoreError.unsupportedSchema }
            guard envelope.sessionID == sessionID, envelope.sequence == entries.count + 1, seen.insert(envelope.transactionID).inserted else { throw StoreError.corruptHistory }
            let transaction: SessionTransaction; var missing = false
            do { transaction = try readLegacyTransaction(envelope) }
            catch StoreError.missingBlob where envelope.recoverableCompaction == true {
                missing = true; transaction = SessionTransaction(id: envelope.transactionID, sessionID: sessionID, kind: .recovery)
            }
            try validateContextTransition(transaction, currentCount: count, ignoreHead: rebuilding)
            let changes = missing || !transaction.contextItems.isEmpty || transaction.snapshot != nil || transaction.contextHead != nil
            revision += changes ? 1 : 0; guard revision == envelope.revision else { throw StoreError.corruptHistory }
            if missing { rebuilding = true }; if transaction.snapshot != nil { rebuilding = false }
            count = transaction.snapshot?.items.count ?? (count + transaction.contextItems.count)
            entries.append(LegacyEntry(envelope: envelope, missing: missing))
        }
        return entries
    }
    private func forEachLine(_ url: URL, startingAt offset: UInt64, limit: Int, body: (Data, UInt64, Int) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        var pending = Data(), lineStart = offset, lineLength = 0, overflow = false
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            var start = chunk.startIndex
            for end in chunk.indices where chunk[end] == 10 {
                let part = chunk[start..<end]; lineLength += part.count + 1
                guard !overflow, pending.count + part.count <= limit else { throw StoreError.tooLarge }
                pending.append(contentsOf: part); try body(pending, lineStart, lineLength)
                lineStart += UInt64(lineLength); lineLength = 0; pending.removeAll(keepingCapacity: true); overflow = false; start = end + 1
            }
            let part = chunk[start...]; lineLength += part.count
            if !overflow && pending.count + part.count <= limit { pending.append(contentsOf: part) }
            else { overflow = true; pending.removeAll() }
        }
        // An unterminated tail is uncommitted, including an oversized torn tail.
    }
    private func digestFile(_ url: URL) throws -> String {
        try requireSafe(url, allowMissing: false)
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    /// Digest the literal transaction value, before optional fields are decoded
    /// or defaulted. This also rejects ambiguous duplicate transaction keys.
    private func rawTransactionDigest(_ line: Data) throws -> String {
        let range: Range<Int> = try line.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self), count = bytes.count
            func whitespace(_ value: UInt8) -> Bool { value == 32 || value == 9 || value == 10 || value == 13 }
            func endString(_ start: Int) throws -> Int {
                guard start < count, bytes[start] == 34 else { throw StoreError.corruptHistory }
                var index = start + 1, escaped = false
                while index < count {
                    let byte = bytes[index]
                    if escaped { escaped = false }
                    else if byte == 92 { escaped = true }
                    else if byte == 34 { return index + 1 }
                    index += 1
                }
                throw StoreError.corruptHistory
            }
            func endValue(_ start: Int) throws -> Int {
                guard start < count else { throw StoreError.corruptHistory }
                if bytes[start] == 34 { return try endString(start) }
                if bytes[start] == 123 || bytes[start] == 91 {
                    var index = start, depth = 0
                    while index < count {
                        switch bytes[index] {
                        case 34: index = try endString(index); continue
                        case 123, 91: depth += 1
                        case 125, 93:
                            depth -= 1
                            if depth == 0 { return index + 1 }
                        default: break
                        }
                        index += 1
                    }
                    throw StoreError.corruptHistory
                }
                var index = start
                while index < count, bytes[index] != 44, bytes[index] != 125, !whitespace(bytes[index]) { index += 1 }
                guard index > start else { throw StoreError.corruptHistory }; return index
            }
            var index = 0
            while index < count, whitespace(bytes[index]) { index += 1 }
            guard index < count, bytes[index] == 123 else { throw StoreError.corruptHistory }; index += 1
            var found: Range<Int>?
            while index < count {
                while index < count, whitespace(bytes[index]) { index += 1 }
                if index < count, bytes[index] == 125 { break }
                let keyStart = index, keyEnd = try endString(index)
                index = keyEnd
                while index < count, whitespace(bytes[index]) { index += 1 }
                guard index < count, bytes[index] == 58 else { throw StoreError.corruptHistory }; index += 1
                while index < count, whitespace(bytes[index]) { index += 1 }
                let valueStart = index, valueEnd = try endValue(index)
                let key: String
                do { key = try JSONDecoder().decode(String.self, from: Data(bytes[keyStart..<keyEnd])) }
                catch { throw StoreError.corruptHistory }
                if key == "transaction" {
                    guard found == nil else { throw StoreError.invalidRecord }
                    found = valueStart..<valueEnd
                }
                index = valueEnd
                while index < count, whitespace(bytes[index]) { index += 1 }
                guard index < count else { throw StoreError.corruptHistory }
                if bytes[index] == 125 { break }
                guard bytes[index] == 44 else { throw StoreError.corruptHistory }; index += 1
            }
            guard let found else { throw StoreError.invalidRecord }; return found
        }
        return SHA256.hash(data: line[range]).map { String(format: "%02x", $0) }.joined()
    }
    private func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        try mutex.withLock {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
            try requireSafe(root, allowMissing: false)
            let lockPath = root.appendingPathComponent(".writer.lock").path
            let fd = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600); guard fd >= 0 else { throw StoreError.io("open lock") }
            defer { close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw StoreError.busy }; defer { flock(fd, LOCK_UN) }
            return try body()
        }
    }
    private func fileIdentity(_ url: URL) throws -> FileStamp {
        var info = stat(); guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw StoreError.invalidPath }
        return FileStamp(device: Int64(info.st_dev), inode: UInt64(info.st_ino), size: UInt64(info.st_size),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanos: Int64(info.st_mtimespec.tv_nsec),
            changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanos: Int64(info.st_ctimespec.tv_nsec))
    }
    private func requireSafe(_ url: URL, allowMissing: Bool) throws {
        var info = stat(); if lstat(url.path, &info) != 0 { if allowMissing && errno == ENOENT { return }; throw StoreError.invalidPath }
        guard (info.st_mode & S_IFMT) != S_IFLNK else { throw StoreError.invalidPath }
    }
    private func syncDirectory(_ url: URL) throws { let fd = open(url.path, O_RDONLY); guard fd >= 0 else { throw StoreError.io("open directory") }; defer { close(fd) }; guard fsync(fd) == 0 else { throw StoreError.io("sync directory") } }
    private func syncFile(_ url: URL) throws { let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }; try h.synchronize() }
    private func validateImages(_ transaction: SessionTransaction) throws {
        func check(_ items: [ModelInputItem]) throws {
            for item in items {
                if case .message(_, let content) = item {
                    for part in content { if case .image(let image) = part, image.fileURL != nil { throw StoreError.invalidPath } }
                }
            }
        }
        try check(transaction.contextItems)
        if let snapshot = transaction.snapshot { try check(snapshot.items) }
        guard transaction.toolResults.allSatisfy({ $0.outcome.images.allSatisfy { $0.fileURL == nil } }) else { throw StoreError.invalidPath }
    }
    private func validateContextTransition(_ transaction: SessionTransaction, currentCount: Int, ignoreHead: Bool = false) throws {
        let count = transaction.snapshot?.items.count ?? (currentCount + transaction.contextItems.count)
        if let snapshot = transaction.snapshot {
            guard snapshot.headCoveredItemCount >= 0, snapshot.headCoveredItemCount <= count,
                  snapshot.preservedNativeItemCount >= 0, snapshot.preservedNativeItemCount <= count else { throw StoreError.invalidRecord }
        }
        if let head = transaction.contextHead, !ignoreHead {
            guard head.coveredItemCount >= 0, head.coveredItemCount <= count else { throw StoreError.invalidRecord }
        }
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
