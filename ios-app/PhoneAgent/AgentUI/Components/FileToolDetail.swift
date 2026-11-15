import SwiftUI

/// Expanded detail for content tools: `read` shows the text that was read,
/// `write`/`edit` render the requested mutation as a diff, and `load_skill`
/// shows the loaded skill document. File tool arguments are stored untruncated
/// for this purpose; every other tool keeps the standard renderer. Plain
/// content, so it can also live inside the approval card's existing scroll
/// region.
struct FileToolDetailContent: View {
    let tool: ToolStep
    /// Caps rendered diff lines so a multi-thousand-line write cannot lay out
    /// an enormous Text block.
    private static let maximumDiffLines = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var content: some View {
        let arguments = (tool.arguments.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]) ?? [:]
        let result = (try? JSONSerialization.jsonObject(with: Data(tool.result.utf8))) as? [String: Any]
        switch tool.name {
        case "read":
            if let fileText = result?["content"] as? String, !fileText.isEmpty {
                labeled(String(localized: "File content")) {
                    Text(verbatim: fileText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
                if (result?["truncated"] as? Bool) == true {
                    Text(String(localized: "Output was truncated."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if !tool.displayResult.isEmpty {
                labeled(String(localized: "Result details")) { resultText }
            } else if let shown = tool.displayArguments {
                ToolArgumentsSection(shown)
            }
        case "write", "edit":
            let diff = Self.diff(tool: tool, arguments: arguments)
            if !diff.lines.isEmpty {
                labeled(String(localized: "Changes")) {
                    Self.diffText(diff.lines)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                if diff.truncated {
                    Text(String(localized: "Only the first \(Self.maximumDiffLines) lines are shown."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if let shown = tool.displayArguments {
                ToolArgumentsSection(shown)
            }
            if !tool.displayResult.isEmpty && tool.state == .failed {
                labeled(String(localized: "Result details")) { resultText }
            }
        case "load_skill":
            if let document = result?["content"] as? String, !document.isEmpty {
                labeled(String(localized: "Skill document")) {
                    Text(verbatim: document)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
            } else if !tool.displayResult.isEmpty {
                labeled(String(localized: "Result details")) { resultText }
            } else if let shown = tool.displayArguments {
                ToolArgumentsSection(shown)
            }
        default:
            if let shown = tool.displayArguments { ToolArgumentsSection(shown) }
        }
    }

    private var resultText: some View {
        Text(tool.displayResult)
            .font(.footnote)
            .foregroundStyle(.primary)
            .textSelection(.enabled)
    }

    private func labeled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: - Diff assembly

    struct DiffLine {
        enum Kind { case same, removed, added }
        let kind: Kind
        let text: String
    }

    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// Trims the common line prefix and suffix so the diff shows only the
    /// replaced span, with its surrounding lines as context.
    private static func trimCommon(_ old: [String], _ new: [String])
        -> (prefix: [String], removed: [String], added: [String], suffix: [String]) {
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        return (Array(old[..<prefix]),
                Array(old[prefix..<old.count - suffix]),
                Array(new[prefix..<new.count - suffix]),
                Array(old[(old.count - suffix)...]))
    }

    private static func diff(tool: ToolStep, arguments: [String: Any]) -> (lines: [DiffLine], truncated: Bool) {
        let source: [DiffLine]
        switch tool.name {
        case "write":
            guard let content = arguments["content"] as? String, !content.isEmpty else { return ([], false) }
            source = lines(content).map { DiffLine(kind: .added, text: $0) }
        case "edit":
            guard let old = arguments["old_string"] as? String, let new = arguments["new_string"] as? String,
                  !old.isEmpty else { return ([], false) }
            let trimmed = trimCommon(lines(old), lines(new))
            source = trimmed.prefix.map { DiffLine(kind: .same, text: $0) }
                + trimmed.removed.map { DiffLine(kind: .removed, text: $0) }
                + trimmed.added.map { DiffLine(kind: .added, text: $0) }
                + trimmed.suffix.map { DiffLine(kind: .same, text: $0) }
        default:
            return ([], false)
        }
        guard source.count > maximumDiffLines else { return (source, false) }
        return (Array(source.prefix(maximumDiffLines)), true)
    }

    private static func diffText(_ lines: [DiffLine]) -> Text {
        var text = Text(verbatim: "")
        for line in lines {
            let symbol: String, color: Color
            switch line.kind {
            case .same: (symbol, color) = ("  ", Color.secondary)
            // Fixed muted hues, readable in light and dark mode; the +/-
            // symbols carry the meaning so the color never works alone.
            case .removed: (symbol, color) = ("- ", Self.removedColor)
            case .added: (symbol, color) = ("+ ", Self.addedColor)
            }
            text = text + Text(verbatim: symbol + line.text + "\n").foregroundColor(color)
        }
        return text
    }

    private static let removedColor = Color(red: 0.78, green: 0.34, blue: 0.34)
    private static let addedColor = Color(red: 0.24, green: 0.60, blue: 0.33)
}

/// Tool-card wrapper capping the detail height like the other styles.
struct FileToolDetail: View {
    let tool: ToolStep

    var body: some View {
        ResultScrollRegion(maxHeight: 320, identifier: "toolResultScroll") {
            FileToolDetailContent(tool: tool).padding(12)
        }
        .padding(.top, 8)
    }
}
