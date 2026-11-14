import Foundation
import CCommandBridge

public struct ShellResult: Codable, Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int
    public let truncated: Bool
    public let timedOut: Bool
}

public enum ShellError: Error, LocalizedError {
    case invalidCommand(String)
    public var errorDescription: String? {
        switch self { case .invalidCommand(let detail): return detail }
    }
}

private final class CommandHandle: @unchecked Sendable {
    let execution = CommandExecution()
}

/// One process-wide command lane; cancellation never releases the lane early.
public actor ShellRuntime {
    public static let shared = ShellRuntime()
    private var pending: Task<Void, Never>?
    private init() {}

    public nonisolated static var availableCommands: [String] { CommandExecution.availableCommands() }

    nonisolated static func decodeOutput(_ value: Any?) -> String {
        if let data = value as? Data {
            return String(decoding: data, as: UTF8.self)
        }
        // Bridge setup failures return textual diagnostics rather than bytes.
        return value as? String ?? ""
    }


    public func run(command: String, workspace: URL, workspaceRoot: URL? = nil, timeout: TimeInterval = 10,
                    beforeDispatch: @escaping @Sendable () async throws -> Void = {}) async throws -> ShellResult {
        guard timeout.isFinite, timeout > 0, timeout <= 60 else {
            throw ShellError.invalidCommand("timeout must be greater than zero and at most 60 seconds")
        }
        let previous = pending
        let job = Task<ShellResult, Error> {
            await previous?.value
            try Task.checkCancellation()
            try await beforeDispatch()
            try Task.checkCancellation()
            try ShellInput.validate(command)
            guard workspace.isFileURL, workspace.path.hasPrefix("/"),
                  (workspaceRoot ?? workspace).isFileURL else {
                throw ShellError.invalidCommand("An absolute file URL is required for the working directory.")
            }
            let handle = CommandHandle()
            let result: ShellResult = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        let raw = handle.execution.run(command: command, directory: workspace,
                                                       root: workspaceRoot ?? workspace, timeout: timeout)
                        continuation.resume(returning: ShellResult(
                            stdout: Self.decodeOutput(raw["stdout"]),
                            stderr: Self.decodeOutput(raw["stderr"]),
                            exitCode: (raw["exitCode"] as? NSNumber)?.intValue ?? 127,
                            truncated: (raw["truncated"] as? NSNumber)?.boolValue ?? false,
                            timedOut: (raw["timedOut"] as? NSNumber)?.boolValue ?? false))
                    }
                }
            } onCancel: { handle.execution.cancel() }
            try Task.checkCancellation()
            return result
        }
        pending = Task { _ = try? await job.value }
        return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }
}
