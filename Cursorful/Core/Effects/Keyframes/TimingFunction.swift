import Foundation
import simd

/// Cubic Bezier timing function. Matches CAMediaTimingFunction behavior.
/// Control points are the standard (x1, y1) and (x2, y2). End points are (0,0) and (1,1).
struct TimingFunction: Codable, Hashable {
    var x1: Double
    var y1: Double
    var x2: Double
    var y2: Double

    static let linear      = TimingFunction(x1: 0,    y1: 0,    x2: 1,    y2: 1)
    static let easeIn      = TimingFunction(x1: 0.42, y1: 0.0,  x2: 1.0,  y2: 1.0)
    static let easeOut     = TimingFunction(x1: 0.0,  y1: 0.0,  x2: 0.58, y2: 1.0)
    static let easeInOut   = TimingFunction(x1: 0.42, y1: 0.0,  x2: 0.58, y2: 1.0)
    /// Cinematic default — strong ease, decelerates smoothly.
    static let cinematic   = TimingFunction(x1: 0.77, y1: 0.0,  x2: 0.175, y2: 1.0)
    static let easeInOutQuart = TimingFunction(x1: 0.76, y1: 0.0, x2: 0.24, y2: 1.0)

    /// Evaluate the bezier at progress t ∈ [0,1]. Solves for u such that B_x(u) = t using
    /// Newton-Raphson with binary-search fallback, then returns B_y(u).
    func value(at t: Double) -> Double {
        let clampedT = max(0, min(1, t))
        let u = solveX(for: clampedT)
        return bezierY(at: u)
    }

    // MARK: - Solvers

    private func bezierX(at u: Double) -> Double {
        let mu = 1 - u
        return 3 * mu * mu * u * x1 + 3 * mu * u * u * x2 + u * u * u
    }

    private func bezierY(at u: Double) -> Double {
        let mu = 1 - u
        return 3 * mu * mu * u * y1 + 3 * mu * u * u * y2 + u * u * u
    }

    private func bezierXDerivative(at u: Double) -> Double {
        let mu = 1 - u
        return 3 * mu * mu * x1 + 6 * mu * u * (x2 - x1) + 3 * u * u * (1 - x2)
    }

    private func solveX(for x: Double) -> Double {
        // Newton's method
        var u = x
        for _ in 0..<8 {
            let xu = bezierX(at: u) - x
            if abs(xu) < 1e-6 { return u }
            let dx = bezierXDerivative(at: u)
            if abs(dx) < 1e-6 { break }
            u -= xu / dx
        }
        // Binary search fallback
        var lo = 0.0, hi = 1.0
        u = x
        while lo < hi {
            let xu = bezierX(at: u)
            if abs(xu - x) < 1e-5 { return u }
            if xu < x { lo = u } else { hi = u }
            u = (lo + hi) / 2
        }
        return u
    }
}
