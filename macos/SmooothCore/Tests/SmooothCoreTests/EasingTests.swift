import XCTest
@testable import SmooothCore

final class EasingTests: XCTestCase {
    func testCurvesMatchJSReference() throws {
        let v = try TestVectors.load()
        XCTAssertFalse(v.easing.isEmpty)
        for sample in v.easing {
            let curve = Easing.curve(sample.curve)
            let got = curve(sample.t)
            // Springs use transcendental functions; allow a slightly looser tol.
            let tol = sample.curve.contains("Spring") ? 1e-9 : 1e-12
            XCTAssertEqual(got, sample.value, accuracy: tol,
                           "curve=\(sample.curve) t=\(sample.t)")
        }
    }

    func testEndpoints() {
        for (name, curve) in Easing.map {
            XCTAssertEqual(curve(0), 0, accuracy: 1e-12, "\(name)(0)")
            XCTAssertEqual(curve(1), 1, accuracy: 1e-12, "\(name)(1)")
        }
    }

    func testUnknownCurveFallsBackToBalanced() {
        XCTAssertEqual(Easing.curve("Nonexistent")(0.5), Easing.easeInOutQuint(0.5), accuracy: 1e-12)
    }
}
