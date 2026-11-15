import Foundation
import AgentKit
import ProviderCore

/// Resolve skill names against the current library when loading.
struct SkillCatalog: Sendable {
    let store: SkillStore
    @MainActor func load(named name: String) throws -> String {
        try Task.checkCancellation()
        let (package, directory) = try store.skill(named: name)
        guard let content = package.documents["SKILL.md"] else { throw AppError.invalid(String(localized: "Could not read the skill")) }
        var object: [String: Any] = ["skill_name": package.name, "resource": "SKILL.md",
                                   "content": content, "available_resources": package.resources]
        if let directory {
            object["directory"] = directory.path
            object["file_path"] = directory.appendingPathComponent("SKILL.md").path
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

struct SkillTool: AgentTool {
    let name: String
    let catalog: SkillCatalog
    let canRead: @Sendable () async -> Bool
    var onResult: (@Sendable (ToolInvocation, ToolOutcome) async -> Void)? = nil
    var description: String {
        "Load the current SKILL.md of a built-in or local skill by name. Returns the complete document and its directory. Read referenced files with the read tool, resolving relative paths from that directory."
    }
    var descriptor: ToolDescriptor {
        .init(name: name, description: description, parameters: DeviceTool.schema(["name": DeviceTool.property("string", "Skill name from SKILL.md metadata")], required: ["name"]))
    }
    func execute(_ invocation: ToolInvocation, context: ToolExecutionContext) async throws -> ToolOutcome {
        try await context.checkCancellation()
        guard await canRead() else { throw CancellationError() }
        let outcome: ToolOutcome
        do {
            guard let parameters = invocation.arguments.foundation as? [String: Any],
                  let skillName = parameters["name"] as? String else { throw AppError.invalid(String(localized: "Arguments could not be displayed")) }
            let result = try await catalog.load(named: skillName)
            try Task.checkCancellation()
            guard await canRead() else { throw CancellationError() }
            outcome = .init(content: result)
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? AppError) == .stopped { throw CancellationError() }
            outcome = .init(kind: .validationFailed, content: (error as? AppError)?.localizedDescription ?? String(localized: "Could not read the skill"))
        }
        await onResult?(invocation, outcome)
        return outcome
    }
}
