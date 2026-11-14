import SwiftUI
import CommandKit

/// Tool-specific details opt in here; all other tools keep the standard renderer.
enum ToolDetailStyle {
    case standard, terminal

    private static let registered: [String: ToolDetailStyle] = ["bash": .terminal]

    static func registered(for name: String) -> ToolDetailStyle {
        registered[name] ?? .standard
    }
}

struct TerminalToolContent {
    let command: String?
    let workdir: String?
    let result: ShellResult?
    let fallback: String

    init(tool: ToolStep) {
        let arguments = tool.arguments.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
        command = arguments?["command"] as? String
        workdir = arguments?["workdir"] as? String
        result = try? JSONDecoder().decode(ShellResult.self, from: Data(tool.result.utf8))
        fallback = result == nil ? tool.displayResult : ""
    }
}

struct TerminalToolDetail: View {
    let tool: ToolStep

    var body: some View {
        let content = TerminalToolContent(tool: tool)
        ResultScrollRegion(maxHeight: 320, identifier: "toolResultScroll") {
            VStack(alignment: .leading, spacing: 12) {
                if let command = content.command {
                    Text(verbatim: "$ " + command)
                        .accessibilityIdentifier("terminalCommand")
                } else if let arguments = tool.displayArguments {
                    Text(verbatim: arguments)
                }
                if let result = content.result {
                    if !result.stdout.isEmpty {
                        Text(verbatim: result.stdout).accessibilityIdentifier("terminalStdout")
                    }
                    if !result.stderr.isEmpty || result.exitCode != 0 {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.exitCode == 0
                                ? String(localized: "Error output")
                                : String(localized: "Error output (exit code: \(result.exitCode))"))
                                .font(.caption)
                            if !result.stderr.isEmpty { Text(verbatim: result.stderr) }
                        }
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("terminalStderr")
                    }
                    if result.timedOut { Text(String(localized: "Command timed out; effects may be incomplete.")) }
                    if result.truncated { Text(String(localized: "Output was truncated.")) }
                } else if !content.fallback.isEmpty {
                    Text(verbatim: content.fallback)
                }
            }
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .accessibilityIdentifier("terminalToolDetail")
    }
}
