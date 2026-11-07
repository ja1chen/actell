import Foundation
import ProviderCore

public enum TokenEstimateMethod: String, Codable, Sendable { case conservativeBytes, usageCalibrated }
public struct TokenEstimate: Sendable, Equatable {
    public let tokens: Int
    public let method: TokenEstimateMethod
    public let revision: Int
    public let safetyMargin: Int
    public init(tokens: Int, method: TokenEstimateMethod, revision: Int, safetyMargin: Int) { self.tokens = tokens; self.method = method; self.revision = revision; self.safetyMargin = safetyMargin }
}
public struct ContextBudget: Sendable, Equatable {
    public static let defaultPlanningTokens = 256 * 1024
    public static let defaultOutputReserve = 4096
    public let planningTokens: Int
    public let hardInputTokens: Int?
    public let hardContextTokens: Int?
    public let outputReserve: Int
    public let toolResultReserve: Int
    public let softFraction: Double
    public let targetFraction: Double
    public init(planningTokens: Int = ContextBudget.defaultPlanningTokens, hardInputTokens: Int? = nil, hardContextTokens: Int? = nil,
                outputReserve: Int = ContextBudget.defaultOutputReserve, toolResultReserve: Int = 4096, softFraction: Double = 0.9, targetFraction: Double = 0.6) {
        self.planningTokens = max(256, planningTokens); self.hardInputTokens = hardInputTokens.map { max(1, $0) }
        self.hardContextTokens = hardContextTokens.map { max(1, $0) }; self.outputReserve = max(0, outputReserve); self.toolResultReserve = max(0, toolResultReserve)
        self.softFraction = min(0.95, max(0.1, softFraction)); self.targetFraction = min(0.9, max(0.1, targetFraction))
    }
    public var effectiveHardInput: Int? {
        let limits = [hardInputTokens, hardContextTokens.map { max(1, $0 - outputReserve) }].compactMap { $0 }
        return limits.min()
    }
    public var effectivePlanning: Int { min(planningTokens, effectiveHardInput ?? planningTokens) }
    public var softThreshold: Int { max(1, Int(Double(effectivePlanning) * softFraction)) }
    public var targetTokens: Int { max(1, Int(Double(effectivePlanning) * targetFraction)) }
}

/// This is a deliberately labelled planning estimate. It is never used as proof of a service hard-limit violation.
public enum ContextEstimator {
    public static func estimate(items: [ModelInputItem], instructions: String, tools: [ModelToolDefinition], revision: Int = 0) -> TokenEstimate {
        var bytes = instructions.utf8.count
        for tool in tools {
            bytes += tool.name.utf8.count + tool.description.utf8.count
            bytes += (try? JSONEncoder().encode(tool.schema).count) ?? 0
        }
        var images = 0
        for item in items { bytes += itemBytes(item, images: &images) }
        let base = max(1, (bytes + 2) / 3 + items.count * 8 + tools.count * 24 + images * 1536)
        let margin = max(32, base / 8)
        return .init(tokens: base + margin, method: .conservativeBytes, revision: revision, safetyMargin: margin)
    }
    private static func itemBytes(_ item: ModelInputItem, images: inout Int) -> Int {
        switch item {
        case .message(_, let content):
            return content.reduce(0) { sum, part in switch part { case .text(let text): return sum + text.utf8.count; case .image: images += 1; return sum + 32 } }
        case .functionResult(let id, let output): return id.utf8.count + output.utf8.count
        case .compacted(let value): return (try? JSONEncoder().encode(value).count) ?? 0
        case .chatReplayState(let value): return (try? JSONEncoder().encode(value).count) ?? 0
        case .replay(let output):
            switch output {
            case .message(let m): return m.content.reduce(0) { sum, part in switch part { case .text(let text, _), .refusal(let text): return sum + text.utf8.count } }
            case .functionCall(let c): return c.id.utf8.count + c.name.utf8.count + c.arguments.utf8.count
            case .reasoning(let r): return r.readableText.utf8.count + (r.encryptedContentForReplay?.utf8.count ?? 0)
            case .compaction(let c): return (try? JSONEncoder().encode(c).count) ?? 0
            case .providerOwned(let value), .unknown(let value): return (try? JSONEncoder().encode(value).count) ?? 0
            }
        }
    }
}
