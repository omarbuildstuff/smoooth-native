import CoreMedia
import Foundation

extension CMTime {
    /// Seconds as Double. 0 for invalid.
    var secondsOrZero: Double {
        guard CMTIME_IS_VALID(self), !CMTIME_IS_INDEFINITE(self) else { return 0 }
        return CMTimeGetSeconds(self)
    }

    static func seconds(_ s: Double, preferredTimescale: CMTimeScale = 600) -> CMTime {
        CMTime(seconds: s, preferredTimescale: preferredTimescale)
    }

    static func frames(_ n: Int, fps: Int32) -> CMTime {
        CMTime(value: CMTimeValue(n), timescale: fps)
    }

    /// Linear interpolation of two CMTimes in seconds.
    static func lerp(_ a: CMTime, _ b: CMTime, _ t: Double) -> CMTime {
        .seconds(a.secondsOrZero + (b.secondsOrZero - a.secondsOrZero) * t)
    }
}

// CMTime: Comparable comes from CoreMedia in recent SDKs.
// CMTime: Codable does NOT come from the SDK — we add it here as a seconds-based encoding.
extension CMTime: @retroactive Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let seconds = try c.decode(Double.self)
        self = CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(self.secondsOrZero)
    }
}
