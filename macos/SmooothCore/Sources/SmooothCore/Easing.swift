import Foundation

/// Easing curves ported verbatim from `src/lib/easing.ts`. The function bodies
/// reproduce the exact arithmetic (including the spring's damped-oscillator
/// formula) so output matches the JS reference to floating-point precision.
public enum Easing {
    public typealias Curve = @Sendable (Double) -> Double

    public static let easeOutQuint: Curve = { t in 1 - pow(1 - t, 5) }

    public static let easeInOutQuint: Curve = { t in
        if t < 0.5 {
            return 16 * t * t * t * t * t
        } else {
            let f = 2 * t - 2
            return 0.5 * f * f * f * f * f + 1
        }
    }

    public static let easeInOutCubic: Curve = { t in
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    /// Damped harmonic oscillator, matching `createSpringEasing`.
    public static func spring(tension: Double = 250, friction: Double = 25, mass: Double = 1) -> Curve {
        let stiffness = tension
        let damping = friction
        let velocity = 0.0
        return { t in
            if t == 0 { return 0 }
            if t == 1 { return 1 }
            let m_w0 = (stiffness / mass).squareRoot()
            let m_zeta = damping / (2 * (stiffness * mass).squareRoot())
            if m_zeta < 1 {
                let m_wd = m_w0 * (1 - m_zeta * m_zeta).squareRoot()
                let b = (m_zeta * m_w0 + -velocity) / m_wd
                return 1 - exp(-t * m_zeta * m_w0)
                    * ((1 + b * sin(m_wd * t)) * cos(m_wd * t) + sin(m_wd * t) * -1)
            } else {
                let g = m_w0
                let h = velocity + m_w0
                return 1 - (exp(-t * g) * (1 + h * t)) / exp(0)
            }
        }
    }

    /// User-facing easing names → curve (matches `EASING_MAP`).
    public static let map: [String: Curve] = [
        "Smooth": easeOutQuint,
        "Balanced": easeInOutQuint,
        "Dynamic": easeInOutCubic,
        "Gentle Spring": spring(tension: 180, friction: 30, mass: 1),
        "Bouncy Spring": spring(tension: 380, friction: 20, mass: 1),
    ]

    /// Resolves a curve by name, falling back to Balanced (matches JS `|| EASING_MAP.Balanced`).
    public static func curve(_ name: String) -> Curve {
        map[name] ?? easeInOutQuint
    }
}
