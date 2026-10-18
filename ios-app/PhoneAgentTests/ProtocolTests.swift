import XCTest
@testable import PhoneAgent

final class ProtocolTests: XCTestCase {
    func testPixelEndpointsAndBounds() throws {
        XCTAssertEqual(try InputCoordinates.normalized(pixel: 0, dimension: 1179), 0)
        XCTAssertEqual(try InputCoordinates.normalized(pixel: 1178, dimension: 1179), 65_535)
        XCTAssertThrowsError(try InputCoordinates.normalized(pixel: 1179, dimension: 1179))
        XCTAssertThrowsError(try InputCoordinates.normalized(pixel: -1, dimension: 1179))
        XCTAssertThrowsError(try InputCoordinates.normalized(pixel: 0, dimension: 1))
    }
    func testEndpointRejectsCredentialsHTTPAndQueries() throws {
        for url in ["http://example.com/v1", "https://name:secret@example.com/v1", "https://example.com/v1?key=secret", "https://example.com/v1#fragment"] {
            XCTAssertThrowsError(try ProviderSettings(baseURL: url, model: "vision").validatedURL())
        }
        XCTAssertEqual(try ProviderSettings(baseURL: "https://example.com/v1", model: "vision").validatedURL().host, "example.com")
        XCTAssertThrowsError(try ProviderSettings(baseURL: "https://example.com/v1", model: " ").validatedURL())
    }
}
