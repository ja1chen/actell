import Foundation

/// Validate the transport envelope, leaving command names, options and syntax to ios_system.
public enum ShellInput {
    public static func validate(_ command: String) throws {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              command.utf8.count <= 8192, !command.contains("\0") else {
            throw ShellError.invalidCommand("Command must be nonempty, contain no NUL bytes, and fit within 8192 UTF-8 bytes.")
        }
    }
}
