import XCTest
@testable import Cursorful

final class TimingFunctionTests: XCTestCase {
    func testLinearIsIdentity() {
        let f = TimingFunction.linear
        XCTAssertEqual(f.value(at: 0.0), 0.0, accuracy: 1e-4)
        XCTAssertEqual(f.value(at: 0.5), 0.5, accuracy: 1e-4)
        XCTAssertEqual(f.value(at: 1.0), 1.0, accuracy: 1e-4)
    }

    func testEaseInOutIsMonotonic() {
        let f = TimingFunction.easeInOut
        var prev = f.value(at: 0)
        for i in 1...20 {
            let v = f.value(at: Double(i) / 20.0)
            XCTAssertGreaterThanOrEqual(v, prev - 1e-6, "non-monotonic at \(i)")
            prev = v
        }
    }

    func testEndpoints() {
        for f in [TimingFunction.easeIn, .easeOut, .easeInOut, .cinematic] {
            XCTAssertEqual(f.value(at: 0), 0.0, accuracy: 1e-3)
            XCTAssertEqual(f.value(at: 1), 1.0, accuracy: 1e-3)
        }
    }
}
