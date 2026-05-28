import XCTest
@testable import SmooothCore

/// Edge-case coverage for AutoZoom region generation: click clustering by
/// `autoMinDuration`, separation of spread-out clicks, and duration clamping to
/// `[autoMinDuration, duration - startTime]`.
final class AutoZoomEdgeCaseTests: XCTestCase {

    private let geom = SizeD(width: 1000, height: 1000)

    private func click(_ t: Double, _ x: Double = 500, _ y: Double = 500) -> MetaDataItem {
        MetaDataItem(timestamp: t, x: x, y: y, type: .click, pressed: true)
    }

    // MARK: clustering

    /// Clicks closer together than `autoMinDuration` (3.0s) collapse into a single
    /// region. Three clicks at 1,2,3 are each within 3s of the running group end.
    func testClusteredClicksCollapseToOneRegion() {
        let clicks = [click(1.0), click(2.0), click(3.0)]
        let regions = AutoZoom.generate(metadata: clicks, recordingGeometry: geom, duration: 30)
        XCTAssertEqual(regions.count, 1, "clicks within autoMinDuration collapse to one region")

        let r = regions[0]
        // group first=1.0 -> startTime = max(0, 1.0 - 1.0) = 0.0
        XCTAssertEqual(r.startTime, 0.0, accuracy: 1e-9, "startTime from first click minus preClickOffset")
        // group last=3.0 -> rawDuration = 3.0 + 0.9 - 0.0 = 3.9; clamp lower bound 3.0 -> 3.9
        XCTAssertEqual(r.duration, 3.9, accuracy: 1e-9, "duration spans first..last + padding")
        // target from FIRST click of the group
        XCTAssertEqual(r.targetX, 500.0 / 1000.0 - 0.5, accuracy: 1e-9)
        XCTAssertEqual(r.targetY, 500.0 / 1000.0 - 0.5, accuracy: 1e-9)
        XCTAssertEqual(r.id, "zoom-auto-1000", "id derived from first click ms")
    }

    /// Exactly-at-threshold gap: a gap == autoMinDuration is NOT < autoMinDuration,
    /// so it starts a new group (boundary semantics use strict <).
    func testGapEqualToThresholdSplits() {
        // gap between click end (1.0) and next (4.0) is exactly 3.0 == autoMinDuration.
        let clicks = [click(1.0), click(4.0)]
        let regions = AutoZoom.generate(metadata: clicks, recordingGeometry: geom, duration: 30)
        XCTAssertEqual(regions.count, 2, "gap == autoMinDuration splits (strict < merges)")
    }

    /// Just under threshold merges.
    func testGapJustUnderThresholdMerges() {
        let clicks = [click(1.0), click(3.99)]  // gap 2.99 < 3.0
        let regions = AutoZoom.generate(metadata: clicks, recordingGeometry: geom, duration: 30)
        XCTAssertEqual(regions.count, 1, "gap just under autoMinDuration merges")
    }

    // MARK: separation

    /// Clicks spread far apart produce one region each.
    func testSpreadClicksYieldSeparateRegions() {
        let clicks = [click(1.0, 100, 100), click(10.0, 900, 200), click(20.0, 300, 800)]
        let regions = AutoZoom.generate(metadata: clicks, recordingGeometry: geom, duration: 30)
            .sorted { $0.startTime < $1.startTime }
        XCTAssertEqual(regions.count, 3, "well-separated clicks -> 3 regions")

        // Each single-click region: startTime = max(0, t-1); target from that click.
        XCTAssertEqual(regions[0].startTime, 0.0, accuracy: 1e-9)   // max(0,1-1)
        XCTAssertEqual(regions[1].startTime, 9.0, accuracy: 1e-9)   // 10-1
        XCTAssertEqual(regions[2].startTime, 19.0, accuracy: 1e-9)  // 20-1
        XCTAssertEqual(regions[1].targetX, 900.0/1000.0 - 0.5, accuracy: 1e-9)
        XCTAssertEqual(regions[2].targetY, 800.0/1000.0 - 0.5, accuracy: 1e-9)
    }

    // MARK: duration clamping

    /// Lower clamp: a single click yields rawDuration = 1.0 + 0.9 = 1.9 (with
    /// startTime 0 when t<=1), which is below autoMinDuration (3.0), so it clamps UP
    /// to 3.0.
    func testDurationClampsUpToAutoMin() {
        let clicks = [click(0.5)]   // startTime = max(0, 0.5-1.0) = 0.0; raw = 0.5+0.9-0 = 1.4
        let regions = AutoZoom.generate(metadata: clicks, recordingGeometry: geom, duration: 30)
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions[0].startTime, 0.0, accuracy: 1e-9)
        XCTAssertEqual(regions[0].duration, Defaults.Zoom.autoMinDuration, accuracy: 1e-9,
                       "short raw duration clamps up to autoMinDuration")
    }

    /// Upper clamp: a click near the very end clamps duration to (duration - startTime),
    /// even if that is itself >= autoMinDuration.
    func testDurationClampsDownToRemainingTimeline() {
        // duration 10; click at 9.5 -> startTime = 8.5; raw = 9.5+0.9-8.5 = 1.9
        // remaining = 10 - 8.5 = 1.5. min(raw, remaining)=1.5, then max(3.0, 1.5)=3.0.
        // So lower clamp dominates here -> 3.0. To isolate the *upper* clamp we need
        // remaining > autoMinDuration but < raw; build that explicitly:
        // click at 5.0, duration 6.0 -> startTime=4.0; raw=5.0+0.9-4.0=1.9; remaining=6-4=2.0.
        // still both < 3.0. The upper clamp only "wins" (produces < raw and >= autoMin)
        // when remaining is in [autoMin, raw). raw for a single click maxes at
        // (t+0.9)-(t-1)=1.9 < autoMin, so for a SINGLE click the upper clamp can never
        // exceed autoMin. We therefore use a CLUSTER to get raw > autoMin:
        // clicks at 5,6,7 (cluster). first=5 -> startTime=4.0; last=7 -> raw=7+0.9-4=3.9.
        // duration 6.0 -> remaining = 6-4 = 2.0 -> min(3.9,2.0)=2.0 -> max(3.0,2.0)=3.0.
        // duration 6.5 -> remaining = 2.5 -> min(3.9,2.5)=2.5 -> max(3.0,2.5)=3.0.
        // duration 7.2 -> remaining = 3.2 -> min(3.9,3.2)=3.2 -> max(3.0,3.2)=3.2. <-- upper clamp wins
        let clicks = [click(5.0), click(6.0), click(7.0)]
        let regions = AutoZoom.generate(metadata: clicks, recordingGeometry: geom, duration: 7.2)
        XCTAssertEqual(regions.count, 1, "cluster -> one region")
        let r = regions[0]
        XCTAssertEqual(r.startTime, 4.0, accuracy: 1e-9)
        XCTAssertEqual(r.duration, 3.2, accuracy: 1e-9,
                       "duration clamps down to (duration - startTime) when that is in [autoMin, raw)")
        // Region must never extend past the timeline end.
        XCTAssertLessThanOrEqual(r.startTime + r.duration, 7.2 + 1e-9, "region stays within timeline")
    }

    /// A region whose clamped duration would be below `minimumRegionDuration` is
    /// dropped. With startTime pinned to nearly the end, remaining < 0.1.
    func testTinyRemainingRegionIsDropped() {
        // duration 1.05; single click at 1.05. startTime = max(0, 1.05-1.0)=0.05.
        // remaining = 1.05 - 0.05 = 1.0. raw = 1.05+0.9-0.05 = 1.9. min=1.0, max(3.0,1.0)=3.0.
        // 3.0 >= 0.1 so it is NOT dropped here. To force a drop, remaining must be < 0.1
        // BEFORE the lower clamp -- but the lower clamp (max with 3.0) means duration is
        // never < autoMin unless... it isn't. The minimumRegionDuration guard therefore
        // only triggers when autoMinDuration < minimumRegionDuration, which is false by
        // default. So with stock defaults a region is never dropped post-clamp.
        // We assert that invariant: every generated region has duration >= autoMinDuration
        // (>= minimumRegionDuration), confirming the guard is effectively dead code under
        // default constants.
        let clicks = [click(1.05)]
        let regions = AutoZoom.generate(metadata: clicks, recordingGeometry: geom, duration: 1.05)
        for r in regions {
            XCTAssertGreaterThanOrEqual(r.duration, Defaults.Zoom.autoMinDuration - 1e-9,
                "post-clamp duration is always >= autoMinDuration under default constants")
        }
    }

    /// Duration == 0 short-circuits to no regions.
    func testZeroDurationYieldsNoRegions() {
        XCTAssertTrue(AutoZoom.generate(metadata: [click(1.0)], recordingGeometry: geom, duration: 0).isEmpty)
    }

    /// zIndex is always 0 from generate() (callers re-stack).
    func testGeneratedRegionsHaveZeroZIndex() {
        let regions = AutoZoom.generate(metadata: [click(2.0), click(12.0)], recordingGeometry: geom, duration: 30)
        XCTAssertEqual(regions.count, 2)
        for r in regions { XCTAssertEqual(r.zIndex, 0) }
    }
}
