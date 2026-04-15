import CoreGraphics
import CoreMedia
import Foundation

/// A single point on the zoom track. `center` is in source-video UV (0..1) and `scale` is the
/// multiplier (1.0 = no zoom, 2.0 = zoomed in 2x).
struct ZoomKeyframe: Codable, Hashable {
    var time: CMTime
    var centerUV: CGPoint
    var scale: CGFloat
}

/// Interpolated sample from a zoom track at a given time.
struct ZoomSample {
    var centerUV: CGPoint
    var scale: CGFloat
    static let identity = ZoomSample(centerUV: CGPoint(x: 0.5, y: 0.5), scale: 1.0)
}
