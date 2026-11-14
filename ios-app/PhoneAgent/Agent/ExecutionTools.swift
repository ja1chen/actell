import Foundation
import CoreFoundation
import AgentKit
import ProviderCore
import CommandKit

/// Host adapters for command execution and file operations, separate from device control.
struct ExecutionTool: AgentTool {
    enum Kind: String, CaseIterable, Sendable { case bash, read, edit, write }
    let kind: Kind
    var name: String { kind.rawValue }
    let workspace: FileWorkspace
    let canExecute: @Sendable () async -> Bool
    let approveMutation: @Sendable (ToolInvocation, String) async -> Bool
    var onResult: (@Sendable (ToolInvocation, ToolOutcome) async -> Void)? = nil

    var descriptor: ToolDescriptor {
        let path = DeviceTool.property("string", "Path inside this conversation's workspace; relative paths recommended. No other app data, symlinks, or external directories.")
        let publicDescription = DeviceTool.property("string", "Short public description of this file operation")
        let text = DeviceTool.property("string", "Literal UTF-8 text; never instructions to execute")
        let properties: [String: ProviderCore.JSONValue]
        let required: [String]
        let description: String
        switch kind {
        case .read:
            properties = ["description": publicDescription, "file_path": path, "offset": DeviceTool.property("integer", "First line, 1-based; default 1"), "limit": DeviceTool.property("integer", "Maximum lines, 1..2000; default 2000")]
            required = ["file_path"]
            description = "Read a UTF-8 text file from this conversation's app-owned workspace with line numbers. Bounded output reports truncation. Not a device filesystem reader."
        case .edit:
            properties = ["description": publicDescription, "file_path": path, "old_string": text, "new_string": text, "replace_all": DeviceTool.property("boolean", "Replace every non-overlapping literal match; defaults to false, which requires exactly one match")]
            required = ["file_path", "old_string", "new_string"]
            description = "Atomically replace literal text in an existing workspace file after one-use user approval. old_string must be nonempty. Zero matches or ambiguous matches fail without changing the file. Empty new_string deletes the matched text."
        case .write:
            properties = ["description": publicDescription, "file_path": path, "content": text]
            required = ["file_path", "content"]
            description = "Create or replace a UTF-8 text file in this conversation's workspace after one-use user approval. Parent directories can be created. Atomic file replacement, not arbitrary filesystem access."
        case .bash:
            properties = ["description": DeviceTool.property("string", "Short public description of the command"), "command": DeviceTool.property("string", "Command text to execute. Availability, options and shell syntax are determined at runtime. Use stdout, stderr and the exit code to choose the next step; missing programs return exit 127."), "timeoutMs": DeviceTool.property("integer", "Timeout in milliseconds, 100..30000; default 10000. Requests cancellation rather than enforcing a hard deadline. Partial effects may remain; do not automatically repeat a timed-out command."), "workdir": path]
            required = ["description", "command"]
            description = "Run a command from the selected conversation working directory after one-use approval. Commands may read or modify files with the App's sandbox permissions; the working directory is not filesystem isolation. Shell features depend on the runtime; this is not a full interactive Bash environment. No interactive input or background-job management is provided. Inspect stdout, stderr and the exit code before choosing the next action. Never include secrets in command arguments."
        }
        return .init(name: name, description: description, parameters: .object(["type": .string("object"), "properties": .object(properties), "required": .array(required.map(ProviderCore.JSONValue.string)), "additionalProperties": .bool(true)]), effect: kind == .read ? .readOnly : .localMutation)
    }

    private static let lane = ExecutionToolLane()
    func execute(_ invocation: ToolInvocation, context: ToolExecutionContext) async throws -> ToolOutcome {
        try await Self.lane.perform { try await executeSerial(invocation, context: context) }
    }
    private func executeSerial(_ invocation: ToolInvocation, context: ToolExecutionContext) async throws -> ToolOutcome {
        try await context.checkCancellation()
        guard await canExecute() else { throw CancellationError() }
        let outcome: ToolOutcome
        do {
            guard let values = invocation.arguments.foundation as? [String: Any] else { throw ArgumentError.invalid }
            func string(_ key: String) throws -> String {
                guard let value = values[key] as? String, !value.contains("\0") else { throw ArgumentError.invalid }
                return value
            }
            func integer(_ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
                guard let value = values[key] else { return fallback }
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                      number.doubleValue.rounded() == number.doubleValue, number.doubleValue >= Double(range.lowerBound), number.doubleValue <= Double(range.upperBound) else { throw ArgumentError.invalid }
                return number.intValue
            }
            let content: String
            if kind == .bash {
                let command = try string("command"), description = try string("description")
                guard !description.isEmpty, description.utf8.count <= 1024 else { throw ArgumentError.invalid }
                let workdir = try values["workdir"].map { _ in try string("workdir") } ?? "."
                let directory = try await workspace.directory(filePath: workdir)
                let timeout = try integer("timeoutMs", default: 10000, range: 100...30000)
                try ShellInput.validate(command)
                guard await approveMutation(invocation, description + "\n" + command) else {
                    let denied = ToolOutcome(kind: .denied, content: "Command execution was not approved; no command was dispatched.")
                    await onResult?(invocation, denied)
                    return denied
                }
                let result = try await ShellRuntime.shared.run(command: command, workspace: directory,
                    workspaceRoot: workspace.root, timeout: Double(timeout) / 1000, beforeDispatch: {
                    try await context.checkCancellation()
                    guard await canExecute() else { throw CancellationError() }
                })
                content = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
                if result.timedOut {
                    let unknown = ToolOutcome(kind: .outcomeUnknown, content: content)
                    await onResult?(invocation, unknown)
                    return unknown
                }
            } else {
                if values["description"] != nil {
                    let description = try string("description")
                    guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, description.utf8.count <= 1024 else { throw ArgumentError.invalid }
                }
                let path = try string("file_path")
                if kind == .read {
                    content = try await workspace.read(filePath: path, offset: integer("offset", default: 1, range: 1...Int.max), limit: integer("limit", default: 2000, range: 1...2000))
                } else {
                    let detail: String
                    if kind == .write {
                        let new = try string("content")
                        detail = "\(path)\n\(new.utf8.count) UTF-8 bytes\n" + String(new.prefix(1000))
                    } else {
                        let old = try string("old_string"), new = try string("new_string")
                        guard !old.isEmpty else { throw ArgumentError.invalid }
                        if let value = values["replace_all"] { guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw ArgumentError.invalid } }
                        detail = "\(path)\n- " + String(old.prefix(500)) + "\n+ " + String(new.prefix(500))
                    }
                    guard await approveMutation(invocation, detail) else {
                        let denied = ToolOutcome(kind: .denied, content: "Workspace mutation was not approved; no file change was dispatched.")
                        await onResult?(invocation, denied)
                        return denied
                    }
                    let check: @Sendable () async throws -> Void = {
                        try await context.checkCancellation()
                        guard await canExecute() else { throw CancellationError() }
                    }
                    if kind == .write { content = try await workspace.write(filePath: path, content: string("content"), commitCheck: check) }
                    else { content = try await workspace.edit(filePath: path, oldString: string("old_string"), newString: string("new_string"), replaceAll: values["replace_all"] as? Bool ?? false, commitCheck: check) }
                }
            }
            // A completed atomic mutation remains a fact even if Stop arrives now.
            outcome = .init(content: content)
        } catch is CancellationError { throw CancellationError() }
        catch { outcome = .init(kind: .validationFailed, content: error.localizedDescription) }
        await onResult?(invocation, outcome)
        return outcome
    }
    private enum ArgumentError: LocalizedError {
        case invalid
        var errorDescription: String? { "Invalid execution tool arguments. Check the required fields, value types, and ranges." }
    }
}

/// Conservatively serialize all workspace tool operations, including native command
/// reads and atomic mutations, across run/model instances. Not an OS sandbox.
private actor ExecutionToolLane {
    private var busy = false
    func perform(_ body: @Sendable () async throws -> ToolOutcome) async throws -> ToolOutcome {
        while busy { try await Task.sleep(nanoseconds: 10_000_000) }
        try Task.checkCancellation()
        busy = true
        defer { busy = false }
        return try await body()
    }
}
