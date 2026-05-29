import SwiftUI

/// Design tokens ported from the original Electron/React app (`src/index.css`,
/// the "ocean-blue" theme). Dark is the default look; light is also supported.
/// HSL values from the stylesheet were converted to sRGB once and hard-coded here
/// so the native app matches the web app pixel-for-pixel.
///
/// Usage: `Theme(model.mode).background`, where `mode` is "dark" or "light".
struct Theme {
    let isDark: Bool

    init(_ mode: String) { self.isDark = (mode != "light") }

    private static func c(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    // MARK: - Core tokens

    var background: Color        { isDark ? Self.c(0.0431, 0.0549, 0.0745) : Self.c(0.9804, 0.9804, 0.9804) }
    var foreground: Color        { isDark ? Self.c(0.9765, 0.9804, 0.9843) : Self.c(0.1294, 0.1294, 0.1294) }
    var card: Color              { isDark ? Self.c(0.0667, 0.0824, 0.1098) : Self.c(1.0000, 1.0000, 1.0000) }
    var cardForeground: Color    { foreground }
    var popover: Color           { isDark ? Self.c(0.0745, 0.0902, 0.1255) : Self.c(1.0000, 1.0000, 1.0000) }
    var primary: Color           { isDark ? Self.c(0.3804, 0.6510, 0.9804) : Self.c(0.0000, 0.4824, 1.0000) }
    var primaryForeground: Color { .white }
    var secondary: Color         { isDark ? Self.c(0.1098, 0.1294, 0.1725) : Self.c(0.9608, 0.9608, 0.9608) }
    var secondaryForeground: Color { foreground }
    var muted: Color             { isDark ? Self.c(0.0941, 0.1098, 0.1451) : Self.c(0.9686, 0.9686, 0.9686) }
    var mutedForeground: Color   { isDark ? Self.c(0.5922, 0.6392, 0.7059) : Self.c(0.4588, 0.4588, 0.4588) }
    var accent: Color            { isDark ? Self.c(0.1216, 0.1490, 0.2000) : Self.c(0.9412, 0.9412, 0.9412) }
    var accentForeground: Color  { foreground }
    var destructive: Color       { isDark ? Self.c(0.8824, 0.2784, 0.2784) : Self.c(0.9176, 0.1804, 0.1804) }
    var border: Color            { isDark ? Self.c(0.1412, 0.1686, 0.2196) : Self.c(0.8902, 0.8902, 0.8902) }
    var input: Color             { isDark ? Self.c(0.1098, 0.1294, 0.1725) : Self.c(0.9412, 0.9412, 0.9412) }
    var ring: Color              { primary }
    var sidebar: Color           { isDark ? Self.c(0.0510, 0.0627, 0.0863) : Self.c(0.9765, 0.9765, 0.9765) }
    var sidebarForeground: Color { foreground }
    var sidebarBorder: Color     { isDark ? Self.c(0.1412, 0.1686, 0.2196) : Self.c(0.8706, 0.8706, 0.8706) }

    // MARK: - Region / accent colors (timeline)

    /// Zoom regions use the primary blue.
    var zoom: Color { primary }
    /// Cut regions use the destructive red.
    var cut: Color { destructive }
    /// Speed regions use amber.
    var speed: Color { isDark ? Self.c(0.9647, 0.6588, 0.1373) : Self.c(0.9608, 0.6235, 0.0392) }
    /// Saved/success green (preset "Saved!" state etc.).
    var success: Color { Self.c(0.1294, 0.7686, 0.3647) }

    // MARK: - Radii (rounded-lg ≈ 10, md ≈ 8, sm ≈ 6)
    var radiusLg: CGFloat = 10
    var radiusMd: CGFloat = 8
    var radiusSm: CGFloat = 6
    var radiusXl: CGFloat = 14

    // MARK: - Premium export gradient (matches .btn-export-premium)
    var exportGradient: LinearGradient {
        LinearGradient(
            colors: [primary, primary.opacity(0.85)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Environment plumbing

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme("dark")
}
extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

// MARK: - Reusable styled controls

/// Premium blue gradient button used for the Export action.
/// Mirrors `.btn-export-premium`: primary→primary/85 gradient, white text,
/// inner highlight, soft drop shadow, subtle white border.
struct PremiumButtonStyle: ButtonStyle {
    let theme: Theme
    var height: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: height)
            .background(
                ZStack {
                    theme.exportGradient
                    // inner highlight in the bottom-right corner
                    RadialGradient(colors: [Color.white.opacity(0.28), .clear],
                                   center: .bottomTrailing, startRadius: 0, endRadius: height * 1.6)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusLg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: theme.radiusLg, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Secondary / ghost toolbar button — `secondary` fill, subtle border, hover tint.
struct SoftButtonStyle: ButtonStyle {
    let theme: Theme
    var prominent: Bool = false
    var iconOnly: Bool = false
    var height: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        let fill = prominent ? theme.primary : theme.secondary
        let fg = prominent ? theme.primaryForeground : theme.foreground
        return configuration.label
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(fg)
            .frame(height: height)
            .frame(minWidth: iconOnly ? height : 0)
            .padding(.horizontal, iconOnly ? 0 : 12)
            .background(fill.opacity(configuration.isPressed ? 0.75 : 1))
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusMd, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: theme.radiusMd, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: prominent ? 0 : 1)
            )
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// A card-style surface (rounded, card fill, subtle border) used to group controls.
struct CardSurface: ViewModifier {
    let theme: Theme
    var padding: CGFloat = 14
    var radius: CGFloat? = nil
    func body(content: Content) -> some View {
        let r = radius ?? theme.radiusLg
        content
            .padding(padding)
            .background(theme.card)
            .clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: r, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: 1)
            )
    }
}

extension View {
    func cardSurface(_ theme: Theme, padding: CGFloat = 14, radius: CGFloat? = nil) -> some View {
        modifier(CardSurface(theme: theme, padding: padding, radius: radius))
    }
}
