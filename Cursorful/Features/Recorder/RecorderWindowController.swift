import AppKit
import SwiftUI

/// Floating non-activating panel showing the recorder capsule. Hosts `RecorderBarView`.
@MainActor
final class RecorderWindowController: NSWindowController {

    init() {
        let view = RecorderBarView()
            .environmentObject(AppEnvironment.shared)
        let host = NSHostingController(rootView: view)
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = .clear

        let panel = NonActivatingPanel(contentViewController: host)
        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.isFloatingPanel = true
        panel.level = .mainMenu - 1   // Float below menu bar
        panel.hasShadow = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.setContentSize(NSSize(width: 320, height: 56))
        panel.animationBehavior = .utilityWindow

        // Position: bottom center of main screen, 32pt above bottom edge.
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            let w: CGFloat = 320, h: CGFloat = 56
            let origin = NSPoint(x: f.midX - w/2, y: f.minY + 32)
            panel.setFrameOrigin(origin)
        }

        super.init(window: panel)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.orderFrontRegardless()
    }
}

private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
