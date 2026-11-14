import XCTest
import AgentKit
import ProviderCore
import CommandKit
@testable import PhoneAgent

final class ExecutionToolTests: XCTestCase {
    func testCatalogIncludesBundledCommandsBeyondOriginalSubset() {
        let names = Set(ShellRuntime.availableCommands)
        for command in ["pwd", "cp", "mv", "rm", "mkdir", "sed", "sort", "uniq", "base64", "sh", "sleep"] {
            XCTAssertTrue(names.contains(command), command)
        }
        XCTAssertFalse(names.contains("python"))
    }

    func testMissingCommandReturnsNativeExit127() async throws {
        let workspace = try workspace()
        let result = try await ShellRuntime.shared.run(command: "actell_command_that_does_not_exist --anything", workspace: workspace.root)
        XCTAssertEqual(result.exitCode, 127)
        XCTAssertTrue(result.stderr.contains("command not found"), result.stderr)
        XCTAssertFalse(result.timedOut)
    }

    func testNativeMutationPipesAndPreviouslyFilteredFlags() async throws {
        let workspace = try workspace()
        let commands = ["mkdir -p nested", "echo hello > nested/source.txt", "cp -p nested/source.txt nested/copy.txt",
                        "grep -r hello nested", "cat nested/copy.txt | tr a-z A-Z", "rm nested/copy.txt"]
        for command in commands {
            let result = try await ShellRuntime.shared.run(command: command, workspace: workspace.root)
            XCTAssertEqual(result.exitCode, 0, "\(command): \(result.stderr)")
            if command.contains(" | ") { XCTAssertEqual(result.stdout, "HELLO\n") }
        }
        XCTAssertEqual(try String(contentsOf: workspace.root.appendingPathComponent("nested/source.txt"), encoding: .utf8), "hello\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.root.appendingPathComponent("nested/copy.txt").path))
    }

    func testWorkingDirectoryAndEnvironmentDoNotLeakAcrossCalls() async throws {
        let a = try workspace(), b = try workspace()
        let originalDirectory = FileManager.default.currentDirectoryPath
        let changed = try await ShellRuntime.shared.run(command: "env ACTELL_COMMAND_TEST_MARKER=sample printenv ACTELL_COMMAND_TEST_MARKER", workspace: a.root)
        XCTAssertEqual(changed.stdout, "sample\n")
        let absent = try await ShellRuntime.shared.run(command: "printenv ACTELL_COMMAND_TEST_MARKER", workspace: b.root)
        XCTAssertEqual(absent.stdout, "")
        let pwd = try await ShellRuntime.shared.run(command: "pwd", workspace: b.root)
        let reported = (pwd.stdout.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        XCTAssertEqual(reported, b.root.path)
        XCTAssertEqual(FileManager.default.currentDirectoryPath, originalDirectory)
    }

    func testCommandCanUseParentAbsoluteWorkdirAndChangeDirectories() async throws {
        let base = try workspace(), context = context()
        let conversation = try FileWorkspace(root: base.root.appendingPathComponent("conversation"))
        let tool = ExecutionTool(kind: .bash, workspace: conversation, canExecute: { true }, approveMutation: { _, _ in true })
        func run(_ command: String, workdir: String = ".") async throws -> [String: Any] {
            let args = ["description": "Use sibling directory", "workdir": workdir, "command": command]
            let result = try await tool.execute(call("bash", String(decoding: try JSONEncoder().encode(args), as: UTF8.self), context: context), context: context)
            XCTAssertEqual(result.kind, .returned, result.content)
            let output = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any])
            XCTAssertEqual(output["exitCode"] as? Int, 0, result.content)
            XCTAssertEqual(output["stderr"] as? String, "", result.content)
            return output
        }
        _ = try await run("mkdir -p skills/created", workdir: base.root.path)
        _ = try await run("echo native > reference.txt", workdir: "../skills/created")
        XCTAssertEqual(try String(contentsOf: base.root.appendingPathComponent("skills/created/reference.txt"), encoding: .utf8), "native\n")
        _ = try await run("cd ../skills/created")
        let reset = try await run("pwd")
        let reported = try XCTUnwrap(reset["stdout"] as? String).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual((reported as NSString).expandingTildeInPath, conversation.root.path)
    }

    func testNativeTimeoutWaitsForCommandBeforeReusingRuntime() async throws {
        let workspace = try workspace()
        let start = Date()
        let result = try await ShellRuntime.shared.run(command: "sleep 5", workspace: workspace.root, timeout: 0.2)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.exitCode, 124)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        let next = try await ShellRuntime.shared.run(command: "echo ready", workspace: workspace.root)
        XCTAssertEqual(next.stdout, "ready\n")
    }

    func testDeniedCommandDoesNotDispatchMutation() async throws {
        let workspace = try workspace(), context = context()
        let tool = ExecutionTool(kind: .bash, workspace: workspace, canExecute: { true }, approveMutation: { _, _ in false })
        let result = try await tool.execute(call("bash", #"{"description":"Create test file","command":"touch denied.txt"}"#, context: context), context: context)
        XCTAssertEqual(result.kind, .denied)
        XCTAssertEqual(tool.descriptor.effect, .localMutation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.root.appendingPathComponent("denied.txt").path))
    }

    func testApprovedCommandAndMissingProgramAreReturnedAsToolResults() async throws {
        let workspace = try workspace(), context = context()
        let tool = ExecutionTool(kind: .bash, workspace: workspace, canExecute: { true }, approveMutation: { _, _ in true })
        let result = try await tool.execute(call("bash", #"{"description":"Create test file","command":"touch created.txt"}"#, context: context), context: context)
        XCTAssertEqual(result.kind, .returned)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.root.appendingPathComponent("created.txt").path))
        let missing = try await tool.execute(call("bash", #"{"description":"Check missing program","command":"actell_missing_program"}"#, context: context), context: context)
        XCTAssertEqual(missing.kind, .returned)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(missing.content.utf8)) as? [String: Any])
        XCTAssertEqual(object["exitCode"] as? Int, 127)
    }

    func testCommandFenceIsRecheckedAfterApproval() async throws {
        let workspace = try workspace(), context = context()
        let tool = ExecutionTool(kind: .bash, workspace: workspace, canExecute: { true }, approveMutation: { _, _ in
            await context.fence.invalidate()
            return true
        })
        do {
            _ = try await tool.execute(call("bash", #"{"description":"Create test file","command":"touch fenced.txt"}"#, context: context), context: context)
            XCTFail("A stale command must not dispatch")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.root.appendingPathComponent("fenced.txt").path))
    }

    func testTimedOutCommandReportsUnknownEffects() async throws {
        let workspace = try workspace(), context = context()
        let tool = ExecutionTool(kind: .bash, workspace: workspace, canExecute: { true }, approveMutation: { _, _ in true })
        let result = try await tool.execute(call("bash", #"{"description":"Wait briefly","command":"sleep 5","timeoutMs":200}"#, context: context), context: context)
        XCTAssertEqual(result.kind, .outcomeUnknown)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any])
        XCTAssertEqual(object["exitCode"] as? Int, 124)
    }

    func testNativeReadOnlyCommandsLoadAndExecute() async throws {
        let workspace = try workspace()
        _ = try await workspace.write(filePath: "sample.txt", content: "hello\nworld\n")
        for (command, expected) in [
            ("pwd", workspace.root.path), ("ls", "sample.txt"),
            ("find . -type f", "sample.txt"), ("grep hello sample.txt", "hello"),
            ("cat sample.txt", "hello\nworld"), ("head -n 1 sample.txt", "hello"),
            ("tail -n 1 sample.txt", "world"), ("wc -l sample.txt", "2")
        ] {
            let result = try await ShellRuntime.shared.run(command: command, workspace: workspace.root)
            XCTAssertEqual(result.exitCode, 0, "\(command): \(result.stderr)")
            let output = command == "pwd" ? (result.stdout as NSString).expandingTildeInPath : result.stdout
            XCTAssertTrue(output.contains(expected), "\(command): \(result.stdout)")
            XCTAssertFalse(result.timedOut, command)
        }
        let noMatch = try await ShellRuntime.shared.run(command: "grep absent sample.txt", workspace: workspace.root)
        XCTAssertEqual(noMatch.exitCode, 1)
    }

    func testNativeOutputLimitDrainsChineseText() async throws {
        let workspace = try workspace()
        _ = try await workspace.write(filePath: "large.txt", content: String(repeating: "中", count: 40_000))
        let result = try await ShellRuntime.shared.run(command: "cat large.txt", workspace: workspace.root)
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.truncated)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.stdout, String(repeating: "中", count: 21_845) + "\u{FFFD}")
    }

    private func workspace() throws -> FileWorkspace {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try FileWorkspace(root: root)
    }
    private func context() -> ToolExecutionContext {
        .init(sessionID: UUID(), turnID: UUID(), generation: UUID(), fence: ExecutionFence())
    }
    private func call(_ name: String, _ args: String, context: ToolExecutionContext) -> ToolInvocation {
        .init(sessionID: context.sessionID, turnID: context.turnID, call: .init(id: UUID().uuidString, name: name, arguments: args))
    }
    func testDeniedWriteDoesNotCreateFile() async throws {
        let workspace = try workspace(), context = context()
        let tool = ExecutionTool(kind: .write, workspace: workspace, canExecute: { true }, approveMutation: { _, _ in false })
        let result = try await tool.execute(call("write", #"{"file_path":"a.txt","content":"hello"}"#, context: context), context: context)
        XCTAssertEqual(result.kind, .denied)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.root.appendingPathComponent("a.txt").path))
    }
    func testApprovedWriteAndReadShareWorkspace() async throws {
        let workspace = try workspace(), context = context()
        let write = ExecutionTool(kind: .write, workspace: workspace, canExecute: { true }, approveMutation: { _, _ in true })
        let result = try await write.execute(call("write", #"{"file_path":"a.txt","content":"hello"}"#, context: context), context: context)
        XCTAssertEqual(result.kind, .returned)
        let read = ExecutionTool(kind: .read, workspace: workspace, canExecute: { true }, approveMutation: { _, _ in false })
        let output = try await read.execute(call("read", #"{"file_path":"a.txt"}"#, context: context), context: context)
        XCTAssertTrue(output.content.contains("hello"))
    }
    func testUnknownFieldsIgnoredAndBooleanNumbersRejected() async throws {
        let workspace = try workspace(), context = context()
        _ = try await workspace.write(filePath: "a", content: "hello")
        let tool = ExecutionTool(kind: .read, workspace: workspace, canExecute: { true }, approveMutation: { _, _ in true })
        let output = try await tool.execute(call("read", #"{"file_path":"a","description":"Read the file","sandbox_permissions":"danger-full-access","unknown":{"value":true}}"#, context: context), context: context)
        XCTAssertEqual(output.kind, .returned)
        XCTAssertTrue(output.content.contains("hello"))
        let invalid = try await tool.execute(call("read", #"{"file_path":"a","offset":true}"#, context: context), context: context)
        XCTAssertEqual(invalid.kind, .validationFailed)
    }
    func testInvalidatedFencePreventsDispatch() async throws {
        let workspace = try workspace(), context = context()
        await context.fence.invalidate()
        let tool = ExecutionTool(kind: .write, workspace: workspace, canExecute: { true }, approveMutation: { _, _ in true })
        do {
            _ = try await tool.execute(call("write", #"{"file_path":"a","content":"x"}"#, context: context), context: context)
            XCTFail("Invalidated execution should cancel")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.root.appendingPathComponent("a").path))
    }
}
