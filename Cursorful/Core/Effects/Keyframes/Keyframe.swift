import CoreMedia
import Foundation

/// Generic linear-interpolable keyframe container. Used by timeline tracks that aren't zoom-specific
/// (e.g. volume automation in a future phase).
struct Keyframe<T: Interpolable>: Codable, Hashable where T: Codable, T: Hashable {
    var time: CMTime
    var value: T
}

protocol Interpolable {
    static func lerp(_ a: Self, _ b: Self, _ t: Double) -> Self
}

extension CGFloat: Interpolable {
    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat {
        a + (b - a) * CGFloat(t)
    }
}

extension Double: Interpolable {
    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }
}
