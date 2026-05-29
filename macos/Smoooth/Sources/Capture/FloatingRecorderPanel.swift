import SwiftUI
import AppKit

/// Loom-style floating recording controls: a small, draggable, always-on-top panel
/// that is EXCLUDED from screen capture (`sharingType = .none`) so it never appears
/// in the recording. Shown top-right while recording; the main window is hidden.
@MainActor
final class RecordingHUDController {
    private var panel: NSPanel?

    func show(coordinator: RecordingCoordinator, theme: Theme, recStart: Date,
              onStop: @escaping () -> Void, onCancel: @escaping () -> Void) {
        hide()
        let size = NSSize(width: 268, height: 64)
        let hud = RecordingHUDView(coordinator: coordinator, recStart: recStart, onStop: onStop, onCancel: onCancel)
            .environment(\.theme, theme)
            .frame(width: size.width, height: size.height)

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.sharingType = .none                 // <- never captured by ScreenCaptureKit
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true   // drag from anywhere (Loom-style)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: hud)

        if let vf = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 20, y: vf.maxY - size.height - 20))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// The compact HUD content: drag grip, pulsing REC dot, elapsed time, Stop, Cancel.
private struct RecordingHUDView: View {
    @ObservedObject var coordinator: RecordingCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.theme) private var theme
    let recStart: Date
    let onStop: () -> Void
    let onCancel: () -> Void
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(theme.mutedForeground.opacity(0.6))

            Circle().fill(theme.destructive).frame(width: 11, height: 11)
                .shadow(color: theme.destructive.opacity(0.7), radius: pulse && !reduceMotion ? 6 : 2)
                .opacity(pulse && !reduceMotion ? 0.45 : 1)

            SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(elapsed(ctx.date))
                    .font(.system(size: 17, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(theme.foreground)
            }

            Spacer(minLength: 4)

            Button(action: onStop) {
                HStack(spacing: 5) {
                    Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold))
                    Text("Stop").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12).frame(height: 30)
                .background(theme.destructive)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Stop & edit")

            Button(action: onCancel) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.mutedForeground)
                    .frame(width: 28, height: 30)
            }
            .buttonStyle(.plain)
            .help("Cancel recording")
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.card.opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
        .onAppear { if !reduceMotion { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true } } }
    }

    private func elapsed(_ now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(recStart)))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// Captures the hosting NSWindow so the recording flow can hide/restore it
/// (the main window must not appear in the screen recording).
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { onWindow(v.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(nsView.window) }
    }
}
