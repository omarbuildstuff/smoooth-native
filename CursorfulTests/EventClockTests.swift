import XCTest
import CoreMedia
import Darwin
@testable import Cursorful

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

    /// True round-trip: take current mach ticks, run them through both the seconds-bridge and the
    /// CGEvent-timestamp bridge, verify they agree to within sub-microsecond precision.
    func testCGEventTimestampRoundTripPrecise() {
        let nowTicks = mach_absolute_time()
        let nowSecondsViaBridge = EventClock.seconds(fromCGEventTimestamp: nowTicks)
        let nowSecondsViaNow = EventClock.nowSeconds()
        // The two reads happen sub-microseconds apart; must agree within 1ms.
        XCTAssertEqual(nowSecondsViaBridge, nowSecondsViaNow, accuracy: 0.001)

        // Now feed it through a clock anchored 0.5s before "now" and verify the result is ~0.5s.
        let clock = EventClock(sessionStart: nowSecondsViaNow - 0.5)
        let cmTime = clock.time(fromCGEventTimestamp: nowTicks)
        XCTAssertEqual(cmTime.seconds, 0.5, accuracy: 0.005)
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
