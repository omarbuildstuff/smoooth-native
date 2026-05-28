import XCTest
@testable import SmooothCore

/// Property-style checks on the pure TimeRemap port (no AV dependency). These
/// complement the golden-vector test by asserting structural invariants that must
/// hold for arbitrary cut/speed configurations.
final class TimeRemapPropertyTests: XCTestCase {

    // MARK: monotonicity

    /// Source time must be non-decreasing as export time increases, for any mix of
    /// cut + speed regions. Cuts cause forward jumps; speed regions stretch/compress
    /// but never reverse.
    func testMonotonicNonDecreasing() {
        let duration = 10.0
        let configs: [(cuts: [String: CutRegion], speeds: [String: SpeedRegion], label: String)] = [
            ([:], [:], "passthrough"),
            (["c": CutRegion(id: "c", startTime: 2, duration: 3, zIndex: 0)], [:], "single cut"),
            ([:], ["s": SpeedRegion(id: "s", startTime: 1, duration: 4, speed: 2, zIndex: 0)], "single 2x speed"),
            ([:], ["s": SpeedRegion(id: "s", startTime: 1, duration: 4, speed: 0.5, zIndex: 0)], "single 0.5x speed"),
            (["c1": CutRegion(id: "c1", startTime: 0, duration: 1, zIndex: 0),
              "c2": CutRegion(id: "c2", startTime: 6, duration: 2, zIndex: 0)],
             ["s": SpeedRegion(id: "s", startTime: 2, duration: 2, speed: 3, zIndex: 0)], "two cuts + speed"),
            (["c": CutRegion(id: "c", startTime: 3, duration: 2, zIndex: 0)],
             ["s": SpeedRegion(id: "s", startTime: 3, duration: 2, speed: 2, zIndex: 0)], "overlapping cut+speed (coincident)"),
        ]

        for cfg in configs {
            let exportDur = TimeRemap.exportDuration(duration, cutRegions: cfg.cuts, speedRegions: cfg.speeds)
            let steps = 500
            var prev = -Double.infinity
            for k in 0...steps {
                let et = Double(k) / Double(steps) * exportDur
                let st = TimeRemap.mapExportTimeToSourceTime(et, duration: duration,
                                                             cutRegions: cfg.cuts, speedRegions: cfg.speeds)
                XCTAssertGreaterThanOrEqual(st, prev - 1e-9,
                    "[\(cfg.label)] source time regressed at export=\(et): \(st) < \(prev)")
                XCTAssertGreaterThanOrEqual(st, -1e-9, "[\(cfg.label)] negative source time at export=\(et)")
                XCTAssertLessThanOrEqual(st, duration + 1e-6, "[\(cfg.label)] source past end at export=\(et)")
                prev = st
            }
        }
    }

    // MARK: cut excision

    /// The mapped source range must never linger *inside* a cut region for any export
    /// time. (A cut is excised; the loop jumps to its end.) We sample export times and
    /// assert none lands strictly inside the cut interval.
    func testMappedRangeRespectsCuts() {
        let duration = 8.0
        let cut = CutRegion(id: "c", startTime: 2.0, duration: 3.0, zIndex: 0)   // excise [2,5)
        let cuts = ["c": cut]
        let exportDur = TimeRemap.exportDuration(duration, cutRegions: cuts, speedRegions: [:]) // 5.0
        XCTAssertEqual(exportDur, 5.0, accuracy: 1e-9)

        let steps = 1000
        for k in 0...steps {
            let et = Double(k) / Double(steps) * exportDur
            let st = TimeRemap.mapExportTimeToSourceTime(et, duration: duration, cutRegions: cuts, speedRegions: [:])
            // Allowed to equal the cut start (the instant before the jump) or the cut end,
            // but never strictly interior.
            let strictlyInside = st > cut.startTime + 1e-9 && st < cut.startTime + cut.duration - 1e-9
            XCTAssertFalse(strictlyInside, "export=\(et) mapped into cut interior: source=\(st)")
        }
        // And the boundary behaviour: export time exactly at the cut start maps to start,
        // a hair past maps to the cut end (jump).
        let atStart = TimeRemap.mapExportTimeToSourceTime(2.0, duration: duration, cutRegions: cuts, speedRegions: [:])
        XCTAssertEqual(atStart, 2.0, accuracy: 1e-6)
        let pastStart = TimeRemap.mapExportTimeToSourceTime(2.0 + 1e-4, duration: duration, cutRegions: cuts, speedRegions: [:])
        XCTAssertGreaterThanOrEqual(pastStart, cut.startTime + cut.duration - 1e-3, "should jump over the cut")
    }

    // MARK: whole-timeline cut

    /// A cut covering the entire timeline yields ~0 export duration, and every export
    /// time maps to the end of the source.
    func testFullTimelineCutYieldsZeroDuration() {
        let duration = 6.0
        let cuts = ["c": CutRegion(id: "c", startTime: 0.0, duration: 6.0, zIndex: 0)]
        let exportDur = TimeRemap.exportDuration(duration, cutRegions: cuts, speedRegions: [:])
        XCTAssertEqual(exportDur, 0.0, accuracy: 1e-9, "whole-timeline cut -> zero export duration")

        // Any export time maps to the source end (the single cut segment sets sourceTime=end).
        for et in [0.0, 0.5, 3.0, 6.0] {
            let st = TimeRemap.mapExportTimeToSourceTime(et, duration: duration, cutRegions: cuts, speedRegions: [:])
            XCTAssertEqual(st, duration, accuracy: 1e-9, "export=\(et) under full cut")
        }
    }

    /// A cut that *overshoots* the timeline (startTime 0, duration > duration) still
    /// clamps to zero and never produces negative export duration.
    func testOversizedCutClampsToZero() {
        let duration = 5.0
        let cuts = ["c": CutRegion(id: "c", startTime: 0.0, duration: 9.0, zIndex: 0)]
        let exportDur = TimeRemap.exportDuration(duration, cutRegions: cuts, speedRegions: [:])
        XCTAssertEqual(exportDur, 0.0, accuracy: 1e-9, "oversized cut clamps to 0 (max(0,...))")
    }

    // MARK: speed-only duration identity

    /// Speed regions preserve total source coverage: integrating speed over export
    /// time recovers the full (uncut) source duration. We check the endpoints —
    /// export end maps to source end.
    func testSpeedOnlyEndMapsToSourceEnd() {
        let duration = 10.0
        let speeds = ["s": SpeedRegion(id: "s", startTime: 3, duration: 4, speed: 2.5, zIndex: 0)]
        let exportDur = TimeRemap.exportDuration(duration, cutRegions: [:], speedRegions: speeds)
        // 10 - 4 + 4/2.5 = 10 - 4 + 1.6 = 7.6
        XCTAssertEqual(exportDur, 7.6, accuracy: 1e-9)
        let stEnd = TimeRemap.mapExportTimeToSourceTime(exportDur, duration: duration, cutRegions: [:], speedRegions: speeds)
        XCTAssertEqual(stEnd, duration, accuracy: 1e-6, "speed-only export end maps to source end")
    }
}
