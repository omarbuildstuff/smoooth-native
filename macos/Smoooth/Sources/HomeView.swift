import SwiftUI
import AppKit

/// Bold first-impression surface. Asymmetric two-column: an oversized SF Rounded
/// wordmark + CTAs on the left, and a signature "framed recording" hero on the
/// right that literally shows what the app produces (padded rounded video frame
/// with a zoom ring + cursor, on one of the app's own wallpapers). One staggered
/// entrance, gated by Reduce Motion. Dark, on-brand — no gradient slop.
struct HomeView: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onImport: () -> Void
    let onRecord: () -> Void

    @State private var appeared = false

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 980
            ZStack {
                theme.background.ignoresSafeArea()
                backdrop

                Group {
                    if wide {
                        HStack(spacing: 56) {
                            leftColumn.frame(maxWidth: 460, alignment: .leading)
                            HeroFrame(theme: theme, reduceMotion: reduceMotion)
                                .frame(maxWidth: .infinity)
                                .reveal(appeared, reduceMotion, delay: 0.18)
                        }
                        .padding(.horizontal, 64)
                    } else {
                        VStack(spacing: 40) {
                            leftColumn
                            HeroFrame(theme: theme, reduceMotion: reduceMotion)
                                .reveal(appeared, reduceMotion, delay: 0.18)
                        }
                        .padding(40)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { appeared = reduceMotion ? true : false; withAnimation { appeared = true } }
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SCREEN RECORDER")
                .font(.system(size: 12, weight: .bold)).tracking(3)
                .foregroundStyle(theme.primary)
                .reveal(appeared, reduceMotion, delay: 0.0)

            Text("Smoooth")
                .font(.system(size: 80, weight: .black, design: .rounded))
                .tracking(-1.5)
                .foregroundStyle(theme.foreground)
                .padding(.top, 10)
                .reveal(appeared, reduceMotion, delay: 0.05)

            Text("Cinematic screen recordings.\nAutomatic pan & zoom — zero keyframing.")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(theme.mutedForeground)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 18)
                .reveal(appeared, reduceMotion, delay: 0.10)

            HStack(spacing: 14) {
                Button { onRecord() } label: {
                    Label("New Recording", systemImage: "record.circle.fill").frame(width: 180)
                }
                .buttonStyle(PremiumButtonStyle(theme: theme, height: 50))
                Button { onImport() } label: {
                    Label("Open Video", systemImage: "folder").frame(width: 140)
                }
                .buttonStyle(SoftButtonStyle(theme: theme, height: 50))
            }
            .font(.system(size: 15, weight: .semibold))
            .padding(.top, 34)
            .reveal(appeared, reduceMotion, delay: 0.15)

            Text("ScreenCaptureKit · Apple Silicon · macOS")
                .font(.system(size: 12, weight: .medium)).tracking(0.5)
                .foregroundStyle(theme.mutedForeground.opacity(0.7))
                .padding(.top, 28)
                .reveal(appeared, reduceMotion, delay: 0.22)
        }
    }

    /// A single restrained brand glow in the navy/blue family (not a purple slop gradient).
    private var backdrop: some View {
        RadialGradient(colors: [theme.primary.opacity(0.10), .clear],
                       center: .init(x: 0.82, y: 0.16), startRadius: 0, endRadius: 620)
            .ignoresSafeArea()
            .blendMode(.plusLighter)
    }
}

// MARK: - Signature hero

/// The product's output, as the hero: a tilted, shadowed, padded rounded-video frame
/// on one of the app's wallpapers, with a focus zoom-ring + cursor + click ripple.
private struct HeroFrame: View {
    let theme: Theme
    let reduceMotion: Bool
    @State private var pulse = false

    var body: some View {
        GeometryReader { geo in
            let w = min(geo.size.width, 560)
            let h = w * 0.66
            ZStack {
                // Canvas = a real Smoooth wallpaper (authentic, not a stock gradient).
                wallpaper
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: w, height: h)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                // The framed "video" (the padded rounded frame the app renders).
                FauxRecording(theme: theme, pulse: pulse, reduceMotion: reduceMotion)
                    .padding(w * 0.08)
                    .frame(width: w, height: h)

                // REC pill, top-left of the canvas.
                recPill
                    .padding(14)
                    .frame(width: w, height: h, alignment: .topLeading)
            }
            .frame(width: w, height: h)
            .shadow(color: .black.opacity(0.5), radius: 40, x: 0, y: 26)
            .rotationEffect(.degrees(-4))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 420)
        .onAppear { if !reduceMotion { withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { pulse = true } } }
    }

    private var wallpaper: Image {
        if let url = Bundle.main.url(forResource: "wallpaper-0001", withExtension: "jpg"),
           let img = NSImage(contentsOf: url) {
            return Image(nsImage: img)
        }
        return Image(systemName: "rectangle.fill")
    }

    private var recPill: some View {
        HStack(spacing: 6) {
            Circle().fill(theme.destructive).frame(width: 8, height: 8)
                .opacity(reduceMotion ? 1 : (pulse ? 0.4 : 1))
            Text("REC").font(.system(size: 10, weight: .heavy)).tracking(1).foregroundStyle(.white)
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(.black.opacity(0.55))
        .clipShape(Capsule())
    }
}

/// A minimal faux "screen being recorded": a dark window with a focus zoom-ring and
/// cursor over a highlighted target — communicates auto-zoom at a glance.
private struct FauxRecording: View {
    let theme: Theme
    let pulse: Bool
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { g in
            let r: CGFloat = 12
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: r, style: .continuous)
                    .fill(theme.card)
                    .overlay(RoundedRectangle(cornerRadius: r, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 1))
                    .shadow(color: .black.opacity(0.45), radius: 22, x: 0, y: 14)

                VStack(alignment: .leading, spacing: 0) {
                    // window chrome
                    HStack(spacing: 6) {
                        ForEach([theme.destructive, theme.speed, theme.success], id: \.self) { c in
                            Circle().fill(c).frame(width: 8, height: 8)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)

                    // content placeholder bars
                    VStack(alignment: .leading, spacing: 9) {
                        bar(width: 0.5, prominent: true)
                        bar(width: 0.8)
                        bar(width: 0.66)
                        HStack(spacing: 8) {
                            target(g)
                            bar(width: 0.3)
                        }
                        bar(width: 0.72)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 2)
                    Spacer(minLength: 0)
                }
            }
            .overlay(zoomRing(g), alignment: .topLeading)
        }
    }

    private func bar(width: CGFloat, prominent: Bool = false) -> some View {
        Capsule()
            .fill(prominent ? theme.foreground.opacity(0.55) : theme.mutedForeground.opacity(0.3))
            .frame(height: prominent ? 9 : 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scaleEffect(x: width, anchor: .leading)
    }

    // The focus target (a "button" the user clicks → triggers zoom).
    private func target(_ g: GeometryProxy) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(theme.primary)
            .frame(width: 64, height: 22)
    }

    // Zoom ring + cursor + ripple, positioned over the target row.
    private func zoomRing(_ g: GeometryProxy) -> some View {
        let cx = g.size.width * 0.18
        let cy = g.size.height * 0.62
        return ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.primary, lineWidth: 2)
                .frame(width: g.size.width * 0.42, height: g.size.height * 0.34)
                .shadow(color: theme.primary.opacity(0.6), radius: 10)
                .position(x: cx + g.size.width * 0.12, y: cy)
                .opacity(reduceMotion ? 0.9 : (pulse ? 1 : 0.65))
            Circle()
                .strokeBorder(theme.primary.opacity(0.5), lineWidth: 2)
                .frame(width: pulse && !reduceMotion ? 34 : 18, height: pulse && !reduceMotion ? 34 : 18)
                .opacity(pulse && !reduceMotion ? 0 : 0.7)
                .position(x: cx + 12, y: cy + 4)
            Image(systemName: "cursorarrow.click.2")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 3, x: 1, y: 1)
                .position(x: cx + 16, y: cy + 8)
        }
    }
}

// MARK: - Staggered reveal

private extension View {
    /// Fade + rise entrance with a per-element delay; instant when Reduce Motion is on.
    func reveal(_ appeared: Bool, _ reduceMotion: Bool, delay: Double) -> some View {
        self
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 14)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.55).delay(delay), value: appeared)
    }
}
