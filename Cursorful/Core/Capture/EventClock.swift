import CoreMedia
import Darwin
import Foundation

/// Single monotonic clock for the entire capture pipeline.
///
/// Zero-point semantics: the clock's session-start is **not** the moment we created the clock —
/// it is the host presentation time of the first delivered video frame (`SCStream`'s first PTS).
/// This is deferred until `anchor(toFirstFramePTS:)` is called.
///
/// Until anchored, cursor samples and click events are buffered by their raw mach time; once the
/// anchor arrives, samples taken earlier get a session-relative time < 0 (which is fine — we clamp
/// to zero at read time or drop them at flush time).
final class EventClock: @unchecked Sendable {

    private static let nanosPerSecond: Double = 1_000_000_000
    private static let timebase: mach_timebase_info = {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return info
    }()

    /// Session start in seconds since mach epoch. Set lazily when the first video frame lands.
    /// Until then, defaults to the clock's instantiation time so cursor-tracking has *some*
    /// reference (samples will be rebased once the anchor is installed).
    private var sessionStartSec: Double
    private var anchored: Bool = false
    private let lock = NSLock()

    /// Current mach time in seconds since boot.
    static func nowSeconds() -> Double {
        let raw = mach_absolute_time()
        let nanos = Double(raw) * Double(timebase.numer) / Double(timebase.denom)
        return nanos / nanosPerSecond
    }

    /// Convert CGEvent timestamp to seconds.
    ///
    /// `CGEventGetTimestamp` returns the event time in nanoseconds (absolute nanoseconds since
    /// boot), **not** in mach ticks. This is true on both Intel and Apple Silicon — the value is
    /// already in nanosecond units, so we divide by 1e9 directly without applying the mach
    /// timebase multiplier.
    ///
    /// Contrast with `mach_absolute_time()`, which IS in platform-dependent ticks and DOES
    /// require the timebase conversion. Using the timebase here would over-inflate the result
    /// by ~41.67× on Apple Silicon (numer=125, denom=3), placing click timestamps far beyond
    /// the recording duration and making AutoZoomPlanner generate regions that never match
    /// any playback time.
    static func seconds(fromCGEventTimestamp nanoseconds: UInt64) -> Double {
        Double(nanoseconds) / nanosPerSecond
    }

    init(sessionStart: Double = EventClock.nowSeconds()) {
        self.sessionStartSec = sessionStart
    }

    /// The anchor time in mach seconds (for persistence in meta.json).
    var sessionStartSeconds: Double {
        lock.withLock { sessionStartSec }
    }

    var isAnchored: Bool { lock.withLock { anchored } }

    /// Install the definitive session-zero from the first `CMSampleBuffer`'s presentation time.
    /// Idempotent — only the first call sticks.
    func anchor(toFirstFramePTSSeconds sec: Double) {
        lock.withLock {
            guard !anchored else { return }
            sessionStartSec = sec
            anchored = true
        }
    }

    /// Convert an absolute mach-time (seconds) to session-relative `CMTime`.
    /// Values before the anchor return `CMTime.zero` (clamped).
    func time(fromMachSeconds seconds: Double) -> CMTime {
        let start = lock.withLock { sessionStartSec }
        let offset = max(0, seconds - start)
        return CMTime(seconds: offset, preferredTimescale: 1_000_000_000)
    }

    /// Convert a CGEvent timestamp (nanoseconds) to session-relative CMTime.
    func time(fromCGEventTimestamp nanoseconds: UInt64) -> CMTime {
        time(fromMachSeconds: Self.seconds(fromCGEventTimestamp: nanoseconds))
    }

    /// Current session-relative time.
    func now() -> CMTime {
        time(fromMachSeconds: Self.nowSeconds())
    }
}

// NSLock.withLock helper for Swift < 5.9 compat
private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        self.lock()
        defer { self.unlock() }
        return try body()
    }
}
