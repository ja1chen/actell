import XCTest
@testable import CommandKit

final class ShellInputTests: XCTestCase {
    func testCommandNamesOptionsAndSyntaxArePassedThrough() throws {
        for command in ["unknown-program --unknown-option", "cp -R source target", "grep -r hello .",
                        "echo hello > result.txt", "cat result.txt | sort", "sh -c 'pwd && ls'",
                        "cat ../other", "echo $ACTELL_COMMAND_TEST_MARKER", "cat 'unterminated"] {
            XCTAssertNoThrow(try ShellInput.validate(command), command)
        }
    }
    func testInvalidTransportEnvelopesAreRejected() {
        for command in ["", " \n\t", "pwd\0ignored", String(repeating: "x", count: 8193), String(repeating: "中", count: 2731)] {
            XCTAssertThrowsError(try ShellInput.validate(command))
        }
    }
    func testByteLimitAllowsBoundaryValue() throws {
        XCTAssertNoThrow(try ShellInput.validate(String(repeating: "x", count: 8192)))
    }
}
