import CoreMedia
import Foundation

/// Tiny helper for transport logic used by both the preview and export paths.
enum PlaybackEngine {
    /// Return frames in [start, end] stepped by 1/fps, inclusive of start.
    static func frameTimes(from start: CMTime, to end: CMTime, fps: Int32) -> AnyIterator<CMTime> {
        var t = start
        let step = CMTime(value: 1, timescale: fps)
        return AnyIterator {
            if t > end { return nil }
            defer { t = CMTimeAdd(t, step) }
            return t
        }
    }
}
