import XCTest
import CoreMedia
import Darwin
@testable import Smoooth

final class EventClockTests: XCTestCase {
    func testSessionRelativeNowIsMonotonic() {
        let clock = EventClock(sessionStart: EventClock.nowSeconds())
        let t1 = clock.now()
        Thread.sleep(forTimeInterval: 0.01)
        let t2 = clock.now()
        XCTAssertGreaterThanOrEqual(t2.seconds, t1.seconds)
    }

    func testMachSecondsToTimeReturnsNonNegative() {
        let origin = EventClock.nowSeconds()
        let clock = EventClock(sessionStart: origin)
        // "Before" session start should clamp to zero.
        let t = clock.time(fromMachSeconds: origin - 5)
        XCTAssertEqual(t.seconds, 0, accuracy: 1e-6)
    }

    /// CGEventTimestamp is in nanoseconds (not mach ticks). Verify that
    /// `seconds(fromCGEventTimestamp:)` divides by 1e9 with no timebase multiply.
    ///
    /// Regression test for the Apple Silicon bug where the old implementation applied the mach
    /// timebase multiplier (~41.67×) to a value already in nanoseconds, producing click timestamps
    /// ~41.67× larger than the recording duration, so AutoZoomPlanner never found a matching
    /// region.
    func testCGEventTimestampIsNanosecondsNotMachTicks() {
        // Feed a known nanosecond value: 5 seconds expressed in nanoseconds.
        let fiveSecondsInNs: UInt64 = 5_000_000_000
        let result = EventClock.seconds(fromCGEventTimestamp: fiveSecondsInNs)
        XCTAssertEqual(result, 5.0, accuracy: 1e-9,
            "CGEventTimestamp is nanoseconds — dividing by 1e9 must yield 5.0, not ~208.0")

        // Verify the old (wrong) formula would have given a wildly different answer.
        // On Apple Silicon numer=125, denom=3: wrong result ≈ 5.0 * (125/3) ≈ 208.33 seconds.
        // We just assert the correct answer is nowhere near 200.
        XCTAssertLessThan(result, 10.0, "Result must not be inflated by the mach timebase ratio")
    }

    /// End-to-end round-trip: synthesise a CGEventTimestamp (in nanoseconds) for a click that
    /// occurs 3.2 seconds into a session, and verify the clock returns ~3.2s.
    func testCGEventTimestampRoundTripPrecise() {
        // sessionStart expressed in seconds (as EventClock.nowSeconds() produces).
        let sessionStartSec = EventClock.nowSeconds()

        // A CGEventTimestamp arrives as absolute nanoseconds since boot.
        // Simulate a click 3.2 seconds after session start.
        let clickOffsetSec = 3.2
        let clickAbsoluteNs = UInt64((sessionStartSec + clickOffsetSec) * 1_000_000_000)

        let clock = EventClock(sessionStart: sessionStartSec)
        let cmTime = clock.time(fromCGEventTimestamp: clickAbsoluteNs)

        // Should be ~3.2 seconds session-relative, within 1ms.
        XCTAssertEqual(cmTime.seconds, clickOffsetSec, accuracy: 0.001,
            "CGEvent click at +3.2s must produce session-relative time of 3.2s")
    }

    /// Anchoring is idempotent — the second call must not reset the zero-point.
    func testAnchorIsIdempotent() {
        let clock = EventClock(sessionStart: 0)
        clock.anchor(toFirstFramePTSSeconds: 100.0)
        XCTAssertEqual(clock.sessionStartSeconds, 100.0, accuracy: 1e-9)
        clock.anchor(toFirstFramePTSSeconds: 200.0) // ignored
        XCTAssertEqual(clock.sessionStartSeconds, 100.0, accuracy: 1e-9)
        XCTAssertTrue(clock.isAnchored)
    }

    /// Pre-anchor samples (at session-relative time < 0) clamp to zero.
    func testPreAnchorSamplesClampToZero() {
        let originalStart = EventClock.nowSeconds()
        let clock = EventClock(sessionStart: originalStart)
        // Anchor 1.0s into the future relative to original session start.
        clock.anchor(toFirstFramePTSSeconds: originalStart + 1.0)
        // A sample taken at originalStart (i.e. *before* the new anchor) should be < anchor.
        let preAnchor = clock.time(fromMachSeconds: originalStart)
        XCTAssertEqual(preAnchor.seconds, 0, accuracy: 1e-9, "pre-anchor times must clamp to 0")
    }
}
