import SwiftUI

@main
struct CursorfulApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var env = AppEnvironment.shared

    var body: some Scene {
        WindowGroup("Cursorful", id: "main") {
            MainWindowView()
                .environmentObject(env)
                .frame(minWidth: 700, minHeight: 480)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Start Recording") {
                    Task { await env.coordinator.startRecording() }
                }
                .keyboardShortcut("2", modifiers: [.shift, .command])

                Button("Stop Recording") {
                    Task { await env.coordinator.stopRecording() }
                }
                .keyboardShortcut(".", modifiers: [.shift, .command])
            }
        }

        Settings {
            PreferencesView()
                .environmentObject(env)
        }
    }
}
