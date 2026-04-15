import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    private var recorderWC: RecorderWindowController?
    private var editorWC: EditorWindowController?
    private var permissionsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("Cursorful launching")

        NSApp.setActivationPolicy(.regular)
        menuBar = MenuBarController()

        // First-run permissions gate
        let permissions = AppEnvironment.shared.permissions
        permissions.refresh()
        if !permissions.hasScreenRecording {
            showPermissionsWindow()
        }

        // React to recording lifecycle → show floating recorder bar
        AppEnvironment.shared.coordinator.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.handleStateChange(state)
            }
        }

        AppEnvironment.shared.coordinator.onFinish = { [weak self] pkg in
            Task { @MainActor in
                AppEnvironment.shared.lastRecording = pkg
                self?.showEditor(for: pkg)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows where window.identifier?.rawValue == "main" {
                window.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }

    // MARK: - Window presentation

    @MainActor
    func showPermissionsWindow() {
        if permissionsWindow == nil {
            let view = PermissionsWindowView()
                .environmentObject(AppEnvironment.shared)
            let host = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: host)
            window.title = "Permissions"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 440, height: 420))
            window.isReleasedWhenClosed = false
            window.center()
            permissionsWindow = window
        }
        permissionsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    func showRecorderBar() {
        if recorderWC == nil { recorderWC = RecorderWindowController() }
        recorderWC?.showWindow(nil)
    }

    @MainActor
    func hideRecorderBar() { recorderWC?.close() }

    @MainActor
    func showEditor(for package: RecordingPackage) {
        editorWC = EditorWindowController(package: package)
        editorWC?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private func handleStateChange(_ state: RecordingCoordinator.State) {
        switch state {
        case .idle:
            hideRecorderBar()
        case .preparing, .recording, .paused:
            showRecorderBar()
        case .stopping, .finalizing:
            // Keep bar visible during finalization
            break
        }
    }
}
