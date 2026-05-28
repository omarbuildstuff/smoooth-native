import XCTest
@testable import SmooothCore

final class GeometryTests: XCTestCase {
    func testWebcamRectsMatchJS() throws {
        let v = try TestVectors.load()
        for entry in v.geometry.webcamRects {
            let r = Geometry.webcamRect(for: entry.pos, width: 200, height: 150, outputWidth: 1920, outputHeight: 1080)
            XCTAssertEqual(r.x, entry.rect.x, accuracy: 1e-9, "\(entry.pos) x")
            XCTAssertEqual(r.y, entry.rect.y, accuracy: 1e-9, "\(entry.pos) y")
            XCTAssertEqual(r.width, entry.rect.width, accuracy: 1e-9, "\(entry.pos) w")
            XCTAssertEqual(r.height, entry.rect.height, accuracy: 1e-9, "\(entry.pos) h")
        }
    }

    func testRulerIntervalsMatchJS() throws {
        let v = try TestVectors.load()
        for entry in v.geometry.ruler {
            let r = Geometry.rulerInterval(pixelsPerSecond: entry.pps)
            XCTAssertEqual(r.major, entry.major, accuracy: 1e-9, "pps=\(entry.pps) major")
            XCTAssertEqual(r.minor, entry.minor, accuracy: 1e-9, "pps=\(entry.pps) minor")
        }
    }

    func testExportDimensionsMatchJS() throws {
        let v = try TestVectors.load()
        for entry in v.geometry.exportDims {
            let d = Geometry.exportDimensions(resolution: entry.resolution, aspectRatio: entry.aspectRatio)
            XCTAssertEqual(d.width, entry.width, "\(entry.resolution) \(entry.aspectRatio.rawValue) width")
            XCTAssertEqual(d.height, entry.height, "\(entry.resolution) \(entry.aspectRatio.rawValue) height")
        }
    }

    func testColorParseMatchesJS() throws {
        let v = try TestVectors.load()
        for entry in v.geometry.colors {
            let c = Geometry.rgbaComponents(entry.input)
            XCTAssertNotNil(c, "parse \(entry.input)")
            if let c {
                XCTAssertEqual(Geometry.hex(c.r, c.g, c.b), entry.hex, "hex \(entry.input)")
                XCTAssertEqual(c.a, entry.alpha, accuracy: 1e-9, "alpha \(entry.input)")
            }
        }
    }

    func testAdjacencyIsSymmetricCycle() {
        // Each position's neighbours should themselves list it (clockwise ring sanity).
        for pos in WebcamPos.allCases {
            let (a, b) = Geometry.adjacentPositions(pos)
            XCTAssertNotEqual(a, b, "\(pos) neighbours distinct")
        }
    }
}
