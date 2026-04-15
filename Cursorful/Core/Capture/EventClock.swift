import CoreMedia
import Darwin
import Foundation

/// Single monotonic clock for the entire capture pipeline.
///
/// Every click, cursor sample, and video frame is stamped in the same coordinate system:
/// mach_absolute_time converted to seconds via mach_timebase_info.
///
/// `SCStream` and `CGEventTap` both deliver mach timestamps natively, so this class just bridges
/// them into a common `CMTime` representation with a shared zero-point chosen at session start.
final class EventClock: @unchecked Sendable {

    private static let nanosPerSecond: Double = 1_000_000_000
    private static let timebase: mach_timebase_info = {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return info
    }()

    /// Start time (in seconds since mach epoch) chosen as the zero-point of the session.
    private let sessionStartSec: Double

    /// Returns the current mach time as seconds (epoch = boot).
    static func nowSeconds() -> Double {
        let raw = mach_absolute_time()
        let nanos = Double(raw) * Double(timebase.numer) / Double(timebase.denom)
        return nanos / nanosPerSecond
    }

    init(sessionStart: Double = EventClock.nowSeconds()) {
        self.sessionStartSec = sessionStart
    }

    /// The session start time in seconds since mach epoch.
    var sessionStartSeconds: Double { sessionStartSec }

    /// Convert an absolute mach-time (seconds) to a session-relative CMTime.
    func time(fromMachSeconds seconds: Double) -> CMTime {
        let offset = max(0, seconds - sessionStartSec)
        return CMTime(seconds: offset, preferredTimescale: 1_000_000_000)
    }

    /// Convert a CGEvent timestamp (mach absolute ticks) to a session-relative CMTime.
    func time(fromCGEventTimestamp ticks: UInt64) -> CMTime {
        let seconds = Double(ticks) * Double(Self.timebase.numer)
            / Double(Self.timebase.denom) / Self.nanosPerSecond
        return time(fromMachSeconds: seconds)
    }

    /// Current session-relative time (seconds since session start).
    func now() -> CMTime {
        time(fromMachSeconds: Self.nowSeconds())
    }
}
