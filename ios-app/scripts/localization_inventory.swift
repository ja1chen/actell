// Parse Swift syntax rather than matching quoted text with regular expressions.
import Foundation
import SwiftSyntax
import SwiftParser
final class Strings: SyntaxVisitor {
    let path: String
    var entries: [[String: Any]] = []
    init(_ path: String) { self.path = path; super.init(viewMode: .sourceAccurate) }
    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        var parent = node.parent
        var contexts: [String] = []
        var nested = false
        while let value = parent {
            if value.is(StringLiteralExprSyntax.self) { nested = true }
            if let call = value.as(FunctionCallExprSyntax.self) { contexts.append(call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text ?? call.calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text ?? "call") }
            if let variable = value.as(VariableDeclSyntax.self) { contexts.append("var:" + variable.bindings.map { $0.pattern.trimmedDescription }.joined(separator: ",")) }
            if let fn = value.as(FunctionDeclSyntax.self) { contexts.append("func:" + fn.name.text) }
            if let declaration = value.as(StructDeclSyntax.self) { contexts.append("type:" + declaration.name.text) }
            if let declaration = value.as(ClassDeclSyntax.self) { contexts.append("type:" + declaration.name.text) }
            if let declaration = value.as(EnumDeclSyntax.self) { contexts.append("type:" + declaration.name.text) }
            if value.is(EnumCaseDeclSyntax.self) { contexts.append("enumRaw") }
            parent = value.parent
        }
        let segments: [[String: String]] = node.segments.map { segment in
            if let value = segment.as(StringSegmentSyntax.self) { return ["text": value.content.text] }
            return ["expression": segment.as(ExpressionSegmentSyntax.self)!.expressions.trimmedDescription]
        }
        entries.append(["path": path, "start": node.positionAfterSkippingLeadingTrivia.utf8Offset,
                        "end": node.endPositionBeforeTrailingTrivia.utf8Offset,
                        "literal": node.trimmedDescription, "segments": segments,
                        "context": contexts, "nested": nested])
        return .visitChildren
    }
}
var all: [[String: Any]] = []
for path in CommandLine.arguments.dropFirst() {
    let source = try String(contentsOfFile: path, encoding: .utf8)
    let visitor = Strings(path); visitor.walk(Parser.parse(source: source)); all += visitor.entries
}
let data = try JSONSerialization.data(withJSONObject: all, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
