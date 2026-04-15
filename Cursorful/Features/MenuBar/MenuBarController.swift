import AppKit
import SwiftUI

/// Adds a menu bar icon with quick-record actions.
@MainActor
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?

    override init() {
        super.init()
        install()
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: Icons.record, accessibilityDescription: "Cursorful")
            button.imagePosition = .imageOnly
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "Record Screen", action: #selector(recordScreen), keyEquivalent: "2")
            .keyEquivalentModifierMask = [.shift, .command]
        menu.addItem(withTitle: "Record Window", action: #selector(recordWindow), keyEquivalent: "4")
            .keyEquivalentModifierMask = [.shift, .command]
        menu.addItem(withTitle: "Stop Recording", action: #selector(stopRecording), keyEquivalent: ".")
            .keyEquivalentModifierMask = [.shift, .command]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show Cursorful", action: #selector(showMain), keyEquivalent: "")
        menu.addItem(withTitle: "Open Recordings Folder", action: #selector(openFolder), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Cursorful", action: #selector(quit), keyEquivalent: "q")

        // Target menu items to self for routing.
        for itemEntry in menu.items { itemEntry.target = self }

        item.menu = menu
        self.statusItem = item
    }

    @objc private func recordScreen() {
        Task { await AppEnvironment.shared.coordinator.startRecording(mode: .fullscreen) }
    }

    @objc private func recordWindow() {
        Task { await AppEnvironment.shared.coordinator.startRecording(mode: .window) }
    }

    @objc private func stopRecording() {
        Task { await AppEnvironment.shared.coordinator.stopRecording() }
    }

    @objc private func showMain() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.identifier?.rawValue == "main" {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func openFolder() {
        NSWorkspace.shared.open(RecordingStore.rootURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func updateIcon(recording: Bool) {
        guard let button = statusItem?.button else { return }
        let name = recording ? Icons.recordFill : Icons.record
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "Cursorful")
        if recording {
            button.contentTintColor = .systemRed
        } else {
            button.contentTintColor = nil
        }
    }
}
