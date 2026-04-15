import XCTest
import CoreMedia
@testable import Cursorful

final class AutoZoomPlannerTests: XCTestCase {

    private func click(at seconds: Double, x: CGFloat = 100, y: CGFloat = 100) -> ClickEvent {
        ClickEvent(time: CMTime(seconds: seconds, preferredTimescale: 1_000_000_000),
                   position: CGPoint(x: x, y: y),
                   button: .left,
                   modifiers: 0,
                   isDown: true)
    }

    func testSingleClickProducesOneRegion() {
        let clicks = [click(at: 2.0)]
        let regions = AutoZoomPlanner.plan(
            clicks: clicks,
            sourceSize: CGSize(width: 1920, height: 1080),
            totalDuration: CMTime(seconds: 10, preferredTimescale: 600)
        )
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions[0].keyframes.count, 4)
    }

    func testClickClusterMergesIntoGesture() {
        // Three clicks within the cluster window → single region, not three.
        let clicks = [click(at: 1.0), click(at: 1.4), click(at: 1.9)]
        let regions = AutoZoomPlanner.plan(
            clicks: clicks,
            sourceSize: CGSize(width: 1920, height: 1080),
            totalDuration: CMTime(seconds: 10, preferredTimescale: 600)
        )
        XCTAssertEqual(regions.count, 1)
    }

    func testSeparatedClicksProduceSeparateRegions() {
        let clicks = [click(at: 1.0), click(at: 5.0), click(at: 8.0)]
        let regions = AutoZoomPlanner.plan(
            clicks: clicks,
            sourceSize: CGSize(width: 1920, height: 1080),
            totalDuration: CMTime(seconds: 10, preferredTimescale: 600)
        )
        XCTAssertEqual(regions.count, 3)
    }

    func testEvaluateIdentityOutsideRegions() {
        let clicks = [click(at: 5.0)]
        let regions = AutoZoomPlanner.plan(
            clicks: clicks,
            sourceSize: CGSize(width: 1920, height: 1080),
            totalDuration: CMTime(seconds: 10, preferredTimescale: 600)
        )
        let sample = AutoZoomPlanner.evaluate(regions: regions,
                                              at: CMTime(seconds: 0.1, preferredTimescale: 600))
        XCTAssertEqual(sample.scale, 1.0, accuracy: 1e-3)
    }

    func testEvaluateZoomedInsideRegion() {
        let clicks = [click(at: 5.0, x: 960, y: 540)]
        let regions = AutoZoomPlanner.plan(
            clicks: clicks,
            sourceSize: CGSize(width: 1920, height: 1080),
            totalDuration: CMTime(seconds: 10, preferredTimescale: 600)
        )
        // Evaluate at click time → should be zoomed in (scale > 1.5)
        let sample = AutoZoomPlanner.evaluate(regions: regions,
                                              at: CMTime(seconds: 5.0, preferredTimescale: 600))
        XCTAssertGreaterThan(sample.scale, 1.5)
        XCTAssertEqual(sample.centerUV.x, 0.5, accuracy: 0.01)
        XCTAssertEqual(sample.centerUV.y, 0.5, accuracy: 0.01)
    }
}
