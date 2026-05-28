import XCTest
@testable import SmooothCore

final class ModelsTests: XCTestCase {
    func testMetadataDecode() throws {
        let json = """
        {"timestamp": 1.25, "x": 100, "y": 200, "type": "click", "pressed": true, "button": "left"}
        """.data(using: .utf8)!
        let item = try JSONDecoder().decode(MetaDataItem.self, from: json)
        XCTAssertEqual(item.timestamp, 1.25)
        XCTAssertEqual(item.x, 100)
        XCTAssertEqual(item.type, .click)
        XCTAssertEqual(item.pressed, true)
        XCTAssertNil(item.cursorImageKey)
    }

    func testZoomRegionDecodeIgnoresExtraKeys() throws {
        let json = """
        {"id":"z1","type":"zoom","startTime":1.0,"duration":3.0,"zoomLevel":2.0,
         "easing":"Balanced","transitionDuration":1.0,"targetX":0.1,"targetY":0.05,
         "mode":"auto","zIndex":10}
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(ZoomRegion.self, from: json)
        XCTAssertEqual(r.id, "z1")
        XCTAssertEqual(r.mode, .auto)
        XCTAssertEqual(r.zoomLevel, 2.0)
        XCTAssertEqual(r.zIndex, 10)
    }

    func testAspectRatioComponents() {
        XCTAssertEqual(AspectRatio.r16x9.components.w, 16)
        XCTAssertEqual(AspectRatio.r9x16.components.h, 16)
        XCTAssertEqual(AspectRatio(rawValue: "1:1"), .r1x1)
    }

    func testRoundTripPreset() throws {
        let bg = Background(type: .color, color: "#101010")
        let fs = FrameStyles(padding: 5, background: bg, borderRadius: 16, shadowBlur: 35,
                             shadowOffsetX: 0, shadowOffsetY: 15, shadowColor: "rgba(0,0,0,0.8)",
                             borderWidth: 4, borderColor: "rgba(255,255,255,0.2)")
        let preset = Preset(id: "p1", name: "Default", styles: fs, aspectRatio: .r16x9, isDefault: true)
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(Preset.self, from: data)
        XCTAssertEqual(decoded, preset)
    }
}
