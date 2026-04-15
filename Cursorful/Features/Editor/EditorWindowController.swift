import AppKit
import SwiftUI

@MainActor
final class EditorWindowController: NSWindowController {

    init(package: RecordingPackage) {
        let editor = EditorView(package: package)
            .environmentObject(AppEnvironment.shared)
        let host = NSHostingController(rootView: editor)
        let window = NSWindow(contentViewController: host)
        window.title = "Cursorful — Editor"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.setContentSize(NSSize(width: 1200, height: 760))
        window.minSize = NSSize(width: 960, height: 560)
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }
}
