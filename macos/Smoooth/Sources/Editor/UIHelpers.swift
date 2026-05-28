import SwiftUI
import AppKit
import SmooothCore

/// rgba("r,g,b,a") <-> SwiftUI Color bridge, matching the app's stored color strings.
extension Color {
    init(rgbaString: String) {
        if let c = Geometry.rgbaComponents(rgbaString) {
            self = Color(.sRGB, red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255, opacity: c.a)
        } else if rgbaString.hasPrefix("#") {
            let ns = NSColor(hexString: rgbaString) ?? .black
            self = Color(ns)
        } else {
            self = .black
        }
    }

    /// Serializes to "rgba(r, g, b, a)".
    func rgbaString() -> String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        let a = Double(ns.alphaComponent)
        return "rgba(\(r), \(g), \(b), \(String(format: "%.2f", a)))"
    }

    func hexString() -> String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02x%02x%02x", Int(ns.redComponent * 255), Int(ns.greenComponent * 255), Int(ns.blueComponent * 255))
    }
}

extension NSColor {
    convenience init?(hexString: String) {
        var hex = hexString
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

/// A labeled slider row with a trailing numeric readout.
struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var decimals: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(String(format: "%.\(decimals)f", value)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}

struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption2.bold()).foregroundStyle(.secondary)
            content
        }
        .padding(.vertical, 6)
    }
}
