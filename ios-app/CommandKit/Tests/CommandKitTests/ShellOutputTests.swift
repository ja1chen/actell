import Foundation
import XCTest
@testable import CommandKit

final class ShellOutputTests: XCTestCase {
    func testCaptureLimitPreservesChineseWithIncompleteFinalScalar() {
        // Each 中 occupies three UTF-8 bytes: 65,536 leaves one byte of
        // the next scalar after 21,845 complete characters.
        let complete = String(repeating: "中", count: 21_845)
        let captured = Data((complete + "文").utf8.prefix(65_536))
        XCTAssertEqual(captured.count, 65_536)
        XCTAssertEqual(ShellRuntime.decodeOutput(captured), complete + "\u{FFFD}")
    }

    func testBridgeDiagnosticAndMissingOutput() {
        XCTAssertEqual(ShellRuntime.decodeOutput("无法创建输出流"), "无法创建输出流")
        XCTAssertEqual(ShellRuntime.decodeOutput(nil), "")
    }
}
