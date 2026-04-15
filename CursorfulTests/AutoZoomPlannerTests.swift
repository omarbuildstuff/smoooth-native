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

    // MARK: - N-way merge (I5 regression)

    /// When three gestures' padded time ranges overlap, they should merge into ONE region whose
    /// centroid is the unweighted average of ALL original clicks (not a pairwise running average
    /// that double-weights the later clicks).
    func testThreeOverlappingGesturesMergeWithCorrectCentroid() {
        // Three single-click gestures 1s apart; with leadIn=0.35 + tailOut=0.8, they all overlap.
        let size = CGSize(width: 1000, height: 1000)
        let clicks = [
            click(at: 2.0, x: 100, y: 100),
            click(at: 3.5, x: 900, y: 100),  // clusterWindow=1.5 means new gesture
            click(at: 5.0, x: 500, y: 900),
        ]
        let regions = AutoZoomPlanner.plan(
            clicks: clicks,
            sourceSize: size,
            totalDuration: CMTime(seconds: 10, preferredTimescale: 600)
        )
        XCTAssertEqual(regions.count, 1, "overlapping padded ranges should merge")

        // Centroid should be the unweighted mean of (100,100),(900,100),(500,900).
        // x = (100+900+500)/3 = 500 → UV.x = 0.5
        // y = (100+100+900)/3 ≈ 366.67 → UV.y ≈ 0.367
        // The pairwise running-average bug would produce UV.y ≈ (((100+100)/2 + 900)/2)/1000 ≈ 0.5
        let sample = AutoZoomPlanner.evaluate(regions: regions,
                                              at: CMTime(seconds: 3.5, preferredTimescale: 600))
        XCTAssertEqual(sample.centerUV.x, 0.5,                  accuracy: 0.001)
        XCTAssertEqual(sample.centerUV.y, 1100.0 / 3.0 / 1000,  accuracy: 0.005)
    }

    /// A four-click cluster within the same gesture window uses the true centroid, not a
    /// progressively-biased running average.
    func testCentroidIsMeanOfAllClicks() {
        let clicks = [
            click(at: 1.0,  x: 0,    y: 0),
            click(at: 1.2,  x: 1000, y: 0),
            click(at: 1.4,  x: 0,    y: 1000),
            click(at: 1.6,  x: 1000, y: 1000),
        ]
        let regions = AutoZoomPlanner.plan(
            clicks: clicks,
            sourceSize: CGSize(width: 1000, height: 1000),
            totalDuration: CMTime(seconds: 10, preferredTimescale: 600)
        )
        XCTAssertEqual(regions.count, 1)
        // Centroid (500, 500) → UV (0.5, 0.5)
        let sample = AutoZoomPlanner.evaluate(regions: regions,
                                              at: CMTime(seconds: 1.3, preferredTimescale: 600))
        XCTAssertEqual(sample.centerUV.x, 0.5, accuracy: 0.01)
        XCTAssertEqual(sample.centerUV.y, 0.5, accuracy: 0.01)
    }
}
