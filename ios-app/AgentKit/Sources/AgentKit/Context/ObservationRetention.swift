import Foundation
import ProviderCore

/// Only host-stamped device observations participate. User attachments and canonical native compact items retain their authorization and content.
public struct ObservationRetentionPolicy: Sendable, Equatable {
    public let maximumGroups: Int
    public let maximumImageBytes: Int
    public init(maximumGroups: Int = 3, maximumImageBytes: Int = 8 * 1024 * 1024) {
        self.maximumGroups = max(1, maximumGroups); self.maximumImageBytes = max(1, maximumImageBytes)
    }
}
struct ObservationRetentionCandidate: Sendable {
    let items: [ModelInputItem]
    let removedGroupCount: Int
    let removedBytes: Int
}
enum ObservationRetention {
    static func candidate(items: [ModelInputItem], preservedNativeItemCount: Int, policy: ObservationRetentionPolicy) -> ObservationRetentionCandidate? {
        var order: [String] = [], bytesByID: [String: Int] = [:]
        for (index, item) in items.enumerated() where index >= preservedNativeItemCount {
            guard case .message(_, let parts) = item else { continue }
            for part in parts {
                guard case .image(let image) = part, let id = image.observationID, !id.isEmpty else { continue }
                if bytesByID[id] == nil { order.append(id) }
                let size = image.fileURL.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? image.data.count
                bytesByID[id, default: 0] += size
            }
        }
        var retained = Set<String>(), retainedBytes = 0
        for id in order.reversed() {
            let bytes = bytesByID[id] ?? 0
            // Keep the latest complete observation even when it alone exceeds the planning target.
            if retained.isEmpty || (retained.count < policy.maximumGroups && retainedBytes + bytes <= policy.maximumImageBytes) {
                retained.insert(id); retainedBytes += bytes
            }
        }
        let removed = Set(order).subtracting(retained)
        guard !removed.isEmpty else { return nil }
        let replacement = items.enumerated().compactMap { index, item -> ModelInputItem? in
            guard index >= preservedNativeItemCount, case .message(let role, let parts) = item else { return item }
            let remaining = parts.filter { part in
                if case .image(let image) = part, let id = image.observationID { return !removed.contains(id) }
                return true
            }
            return remaining.isEmpty ? nil : .message(role: role, content: remaining)
        }
        return .init(items: replacement, removedGroupCount: removed.count, removedBytes: removed.reduce(0) { $0 + (bytesByID[$1] ?? 0) })
    }
}
