import CoreGraphics
import Foundation

/// Parses the CSS-ish color strings used by the original app ("#rrggbb",
/// "rgb()/rgba()", and the one "oklch(...)" fallback) into sRGB CGColors.
public enum ColorParse {
    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    public static func cgColor(_ string: String) -> CGColor {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)

        if s.hasPrefix("#") {
            return hex(s) ?? black
        }
        if s.hasPrefix("rgb") {
            if let c = Geometry.rgbaComponents(s) {
                return CGColor(colorSpace: srgb, components: [
                    CGFloat(c.r) / 255, CGFloat(c.g) / 255, CGFloat(c.b) / 255, CGFloat(c.a),
                ]) ?? black
            }
            return black
        }
        if s.hasPrefix("oklch") {
            // The only oklch literal in the source is the dark slate fallback used
            // when a background image is missing. Approximate it in sRGB.
            return CGColor(colorSpace: srgb, components: [0.12, 0.13, 0.18, 1.0]) ?? black
        }
        return black
    }

    /// Returns (r,g,b) 0–1 and alpha for ripple color math, mirroring the JS regex.
    public static func rgbaFloats(_ string: String) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)? {
        guard let c = Geometry.rgbaComponents(string) else { return nil }
        return (CGFloat(c.r) / 255, CGFloat(c.g) / 255, CGFloat(c.b) / 255, CGFloat(c.a))
    }

    static func hex(_ s: String) -> CGColor? {
        var hex = s
        hex.removeFirst()
        guard hex.count == 6 || hex.count == 3 else { return nil }
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard let value = UInt32(hex, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        return CGColor(colorSpace: srgb, components: [r, g, b, 1.0])
    }

    public static let black = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      components: [0, 0, 0, 1])!
}
