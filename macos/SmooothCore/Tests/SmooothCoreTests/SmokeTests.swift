import XCTest
@testable import SmooothCore

final class SmokeTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(SmooothCore.version, "0.1.0")
    }
}
