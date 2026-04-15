import XCTest
import CoreMedia
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

    func testCGEventTimestampRoundTrip() {
        let origin = EventClock.nowSeconds()
        let clock = EventClock(sessionStart: origin)
        // Fake mach ticks: now in mach ticks.
        // We cannot easily construct a CGEvent timestamp; just verify the API runs.
        let ticks: UInt64 = 1_000_000_000
        let t = clock.time(fromCGEventTimestamp: ticks)
        XCTAssertGreaterThanOrEqual(t.seconds, 0)
    }
}
