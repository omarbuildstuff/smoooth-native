import XCTest
@testable import SmooothCore

final class ZoomTransformTests: XCTestCase {
    func testMatchesJSReference() throws {
        let v = try TestVectors.load()
        let zt = v.zoomTransform
        XCTAssertFalse(zt.samples.isEmpty)
        for s in zt.samples {
            let r = ZoomTransform.calculate(currentTime: s.t,
                                            zoomRegions: zt.regions,
                                            metadata: zt.metadata,
                                            recordingGeometry: zt.geometry,
                                            frameContent: zt.frame)
            XCTAssertEqual(r.scale, s.scale, accuracy: 1e-9, "scale @t=\(s.t)")
            XCTAssertEqual(r.translateX, s.translateX, accuracy: 1e-9, "tx @t=\(s.t)")
            XCTAssertEqual(r.translateY, s.translateY, accuracy: 1e-9, "ty @t=\(s.t)")
            let origin = parseTransformOrigin(s.transformOrigin)
            XCTAssertEqual(r.originX, origin.x, accuracy: 1e-9, "originX @t=\(s.t)")
            XCTAssertEqual(r.originY, origin.y, accuracy: 1e-9, "originY @t=\(s.t)")
        }
    }

    func testNoActiveRegionIsIdentity() {
        let r = ZoomTransform.calculate(currentTime: 99, zoomRegions: [:], metadata: [],
                                        recordingGeometry: SizeD(width: 1920, height: 1080),
                                        frameContent: SizeD(width: 1280, height: 720))
        XCTAssertEqual(r, .identity)
    }

    func testBinarySearchIndex() {
        let md = [0.0, 1.0, 2.0, 3.0].map { MetaDataItem(timestamp: $0, x: 0, y: 0, type: .move) }
        XCTAssertEqual(ZoomTransform.findLastMetadataIndex(md, -1), -1)
        XCTAssertEqual(ZoomTransform.findLastMetadataIndex(md, 0), 0)
        XCTAssertEqual(ZoomTransform.findLastMetadataIndex(md, 2.5), 2)
        XCTAssertEqual(ZoomTransform.findLastMetadataIndex(md, 99), 3)
    }
}
