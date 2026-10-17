import XCTest
@testable import PhoneAgent

final class RemoteStrictJSONTests: XCTestCase {
    func testRejectDuplicateKeysAtEveryDepthIncludingEscapes() throws {
        for input in [#"{"v":1,"v":1}"#, #"{"params":{"x":1,"x":2}}"#,
                      #"{"params":[{"a":1,"\u0061":2}]}"#] {
            XCTAssertThrowsError(try RemoteStrictJSON.validate(Data(input.utf8)))
        }
    }
    func testRejectBadSyntaxTrailingBytesAndExcessDepth() throws {
        for input in [#"{"v":1,}"#, #"{"v":tru}"#, #"{"v":1} {}"#,
                      String(repeating: "[", count: 34) + "0" + String(repeating: "]", count: 34)] {
            XCTAssertThrowsError(try RemoteStrictJSON.validate(Data(input.utf8)))
        }
    }
    func testValidEscapesArraysAndDistinctNestedKeys() throws {
        let valid = #"{"v":1,"params":{"a":"quote\" slash\\ unicode\u0061","b":[null,true,-1.2e3,{"a":2}]}}"#
        XCTAssertNoThrow(try RemoteStrictJSON.validate(Data(valid.utf8)))
    }
    @MainActor func testDefaultServiceDoesNotAcceptCallsWithoutLocalActivation() async throws {
        let model = AgentViewModel(loadPersistentState: false)
        let service = RemoteToolsService(model: model)
        let result = await service.handle(body: Data("{}".utf8), headers: [:])
        XCTAssertEqual(result.status, 401)
        service.stop()
    }
}
