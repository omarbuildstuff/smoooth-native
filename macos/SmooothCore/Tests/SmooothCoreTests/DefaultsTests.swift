import XCTest
@testable import SmooothCore

final class DefaultsTests: XCTestCase {
    func testFrameDefaults() {
        XCTAssertEqual(Defaults.Frame.padding.defaultValue, 5)
        XCTAssertEqual(Defaults.Frame.radius.defaultValue, 16)
        XCTAssertEqual(Defaults.Frame.shadowBlur.defaultValue, 35)
        XCTAssertEqual(Defaults.Frame.shadowOffsetY.defaultValue, 15)
        XCTAssertEqual(Defaults.Frame.shadowOpacity.defaultValue, 0.8)
        XCTAssertEqual(Defaults.Frame.borderWidth.defaultValue, 4)
    }

    func testCameraDefaults() {
        XCTAssertEqual(Defaults.Camera.size.defaultValue, 40)
        XCTAssertEqual(Defaults.Camera.radius.defaultValue, 35)
        XCTAssertEqual(Defaults.Camera.smartPositionTransition, 0.5)
        XCTAssertEqual(Defaults.Camera.scaleOnZoomAmount, 0.8)
        XCTAssertEqual(Defaults.Camera.positionDefault, .bottomRight)
        XCTAssertEqual(Defaults.Camera.shapeDefault, .square)
    }

    func testZoomDefaults() {
        XCTAssertEqual(Defaults.Zoom.defaultLevel, 1.5)
        XCTAssertEqual(Defaults.Zoom.defaultDuration, 3.0)
        XCTAssertEqual(Defaults.Zoom.speedOptions["Slow"], 1.5)
        XCTAssertEqual(Defaults.Zoom.speedOptions["Mellow"], 1.0)
        XCTAssertEqual(Defaults.Zoom.speedOptions["Quick"], 0.7)
        XCTAssertEqual(Defaults.Zoom.speedOptions["Rapid"], 0.4)
        XCTAssertEqual(Defaults.Zoom.autoPreClickOffset, 1.0)
        XCTAssertEqual(Defaults.Zoom.autoPostClickPadding, 0.9)
        XCTAssertEqual(Defaults.Zoom.autoMinDuration, 3.0)
        XCTAssertEqual(Defaults.Zoom.defaultTransitionDuration, 1.0)
    }

    func testCursorDefaults() {
        XCTAssertEqual(Defaults.Cursor.scaleDefault, 2)
        XCTAssertEqual(Defaults.Cursor.clickScaleAmount.defaultValue, 0.8)
        XCTAssertEqual(Defaults.Cursor.clickScaleDuration.defaultValue, 0.4)
        XCTAssertFalse(Defaults.Cursor.clickRippleEnabled)
        XCTAssertTrue(Defaults.Cursor.clickScaleEnabled)
    }

    func testResolutions() {
        XCTAssertEqual(Defaults.Resolutions.p720, SizeI(width: 1280, height: 720))
        XCTAssertEqual(Defaults.Resolutions.p1080, SizeI(width: 1920, height: 1080))
        XCTAssertEqual(Defaults.Resolutions.k2, SizeI(width: 2560, height: 1440))
    }
}
