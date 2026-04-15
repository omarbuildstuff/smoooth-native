import CoreGraphics
import Foundation

extension CGPoint {
    static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}

extension CGFloat {
    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }

    func clamped(_ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        Swift.min(Swift.max(self, lower), upper)
    }
}

extension Double {
    func clamped(_ lower: Double, _ upper: Double) -> Double {
        Swift.min(Swift.max(self, lower), upper)
    }
}

extension CGRect {
    /// Centered CGPoint of the rect.
    var center: CGPoint { CGPoint(x: midX, y: midY) }

    /// Returns a rect that encloses `points` with optional padding.
    static func bounding(_ points: [CGPoint], padding: CGFloat = 0) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points.dropFirst() {
            minX = Swift.min(minX, p.x); minY = Swift.min(minY, p.y)
            maxX = Swift.max(maxX, p.x); maxY = Swift.max(maxY, p.y)
        }
        return CGRect(x: minX - padding, y: minY - padding,
                      width: maxX - minX + padding * 2,
                      height: maxY - minY + padding * 2)
    }
}
