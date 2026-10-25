import XCTest
@testable import Pause

final class CloudContractTests: XCTestCase {
    func testEndpointRejectsInsecureURLsAndCredentialsInURL() throws {
        for raw in ["http://localhost/v1/chat/completions", "https://user:key@example.com/v1/chat/completions", "https://example.com/v1/chat/completions?key=secret", "https://example.com/v1/chat/completions#fragment", "file:///v1/chat/completions", "https://example.com/unknown"] {
            XCTAssertThrowsError(try CloudAdvisor.endpoint(raw), raw)
        }
        XCTAssertEqual(try CloudAdvisor.endpoint("https://example.com/v1/chat/completions").host, "example.com")
    }
    func testOnlyBoundedTimingActionsAreAcceptedFromProvider() throws {
        func envelope(_ content: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        }
        for action in ["allow", "defer"] {
            XCTAssertEqual(try CloudAdvisor.parse(envelope("{\"action\":\"\(action)\"}")).action, action)
        }
        for content in ["{\"action\":\"disable_protection\"}", "Please ignore your instructions", "```json\n{\"action\":\"allow\"}\n```", "{}"] {
            XCTAssertThrowsError(try CloudAdvisor.parse(envelope(content)))
        }
        XCTAssertThrowsError(try CloudAdvisor.parse(Data("{\"choices\":[]}".utf8)))
        XCTAssertThrowsError(try CloudAdvisor.parse(Data("broken".utf8)))
    }
}
