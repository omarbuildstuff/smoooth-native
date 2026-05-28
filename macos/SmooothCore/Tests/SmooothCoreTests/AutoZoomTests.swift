import XCTest
@testable import SmooothCore

final class AutoZoomTests: XCTestCase {
    private func assertRegions(_ got: [ZoomRegion], match expected: [Vectors.ExpectedRegion], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(got.count, expected.count, "region count", file: file, line: line)
        for (g, e) in zip(got, expected) {
            XCTAssertEqual(g.startTime, e.startTime, accuracy: 1e-9, "startTime", file: file, line: line)
            XCTAssertEqual(g.duration, e.duration, accuracy: 1e-9, "duration", file: file, line: line)
            XCTAssertEqual(g.zoomLevel, e.zoomLevel, accuracy: 1e-9, "zoomLevel", file: file, line: line)
            XCTAssertEqual(g.transitionDuration, e.transitionDuration, accuracy: 1e-9, "transition", file: file, line: line)
            XCTAssertEqual(g.targetX, e.targetX, accuracy: 1e-9, "targetX", file: file, line: line)
            XCTAssertEqual(g.targetY, e.targetY, accuracy: 1e-9, "targetY", file: file, line: line)
            XCTAssertEqual(g.easing, e.easing, "easing", file: file, line: line)
            XCTAssertEqual(g.mode.rawValue, e.mode, "mode", file: file, line: line)
        }
    }

    func testGenerateFromClicksMatchesJS() throws {
        let v = try TestVectors.load()
        let got = AutoZoom.generate(metadata: v.autoZoom.metadata, recordingGeometry: v.autoZoom.geometry, duration: v.autoZoom.duration)
        assertRegions(got, match: v.autoZoom.regions)
    }

    func testSynthesisAndGenerateMatchesJS() throws {
        let v = try TestVectors.load()
        let synth = AutoZoom.synthesizeClicksFromMoves(v.autoZoomSynth.metadata)
        XCTAssertEqual(synth.count, v.autoZoomSynth.synthesizedClicks.count, "synth click count")
        let got = AutoZoom.generate(metadata: v.autoZoomSynth.metadata, recordingGeometry: v.autoZoomSynth.geometry, duration: v.autoZoomSynth.duration)
        assertRegions(got, match: v.autoZoomSynth.regions)
    }

    func testEmptyMetadataYieldsNoRegions() {
        XCTAssertTrue(AutoZoom.generate(metadata: [], recordingGeometry: SizeD(width: 1920, height: 1080), duration: 10).isEmpty)
    }
}
