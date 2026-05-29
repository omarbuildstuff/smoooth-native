import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SmooothCore

struct ContentView: View {
    @State private var model = EditorModel()
    @StateObject private var recorder = RecordingCoordinator()
    @State private var screen: Screen = .home
    @State private var hud = RecordingHUDController()
    @State private var countdownHUD = CountdownOverlayController()
    @State private var mainWindow: NSWindow?

    enum Screen { case home, recorder, editor }

    private var theme: Theme { Theme(model.mode) }

    @State private var recorderSize: CGSize = CGSize(width: 520, height: 560)

    var body: some View {
        Group {
            switch screen {
            case .home:
                HomeView(onImport: importVideo, onRecord: { screen = .recorder })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(minWidth: 1000, minHeight: 700)
            case .recorder:
                // Sized to the card — the window shrinks to fit (no black margin).
                RecorderView(coordinator: recorder,
                             onStart: { options in startRecording(options) },
                             onBack: { screen = .home },
                             onSize: { size in
                                 recorderSize = size
                                 if screen == .recorder { applyWindowSize(size, resizable: false) }
                             })
            case .editor:
                EditorView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(minWidth: 1100, minHeight: 740)
            }
        }
        .environment(\.theme, theme)
        .preferredColorScheme(model.mode == "dark" ? .dark : .light)
        .background(WindowAccessor { if let w = $0 { mainWindow = w } })
        .onChange(of: screen) { _, new in applyWindowSizing(for: new) }
    }

    private func applyWindowSizing(for screen: Screen) {
        switch screen {
        case .recorder: applyWindowSize(recorderSize, resizable: false)
        case .home: applyWindowSize(CGSize(width: 1100, height: 760), resizable: true)
        case .editor: applyWindowSize(CGSize(width: 1280, height: 820), resizable: true)
        }
    }

    private func applyWindowSize(_ size: CGSize, resizable: Bool) {
        guard let w = mainWindow else { return }
        if resizable { w.styleMask.insert(.resizable) } else { w.styleMask.remove(.resizable) }
        w.contentMinSize = size
        w.contentMaxSize = resizable ? NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude) : size
        let frame = w.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        var newFrame = w.frame
        newFrame.origin.y += newFrame.height - frame.height   // keep top edge fixed
        newFrame.size = frame.size
        w.setFrame(newFrame, display: true, animate: true)
        w.center()
    }

    // MARK: - Recording flow (Loom-style floating HUD; main window hidden during capture)

    private func startRecording(_ options: RecordingOptions) {
        // Hide the main window BEFORE capture starts so Smoooth never appears in the recording.
        mainWindow?.orderOut(nil)
        // Pre-warm countdown overlay (camera/mic/screen warm up; writing starts at 0).
        countdownHUD.show(coordinator: recorder, theme: theme)
        Task {
            do {
                try await recorder.start(options: options)
                countdownHUD.hide()
                hud.show(coordinator: recorder, theme: theme, recStart: Date(),
                         onStop: { stopRecording() }, onCancel: { cancelRecording() })
            } catch {
                countdownHUD.hide()
                mainWindow?.makeKeyAndOrderFront(nil)
                screen = .recorder
                presentAlert("Recording failed", message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func stopRecording() {
        Task {
            do {
                let result = try await recorder.stop()
                hud.hide()
                await model.loadProject(videoURL: result.screenVideoURL,
                                        metadataURL: result.metadataURL,
                                        webcamVideoURL: result.webcamVideoURL)
                screen = .editor
                mainWindow?.makeKeyAndOrderFront(nil)
            } catch {
                hud.hide()
                screen = .home
                mainWindow?.makeKeyAndOrderFront(nil)
                presentAlert("Couldn't save recording", message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func cancelRecording() {
        Task {
            await recorder.cancel()
            hud.hide()
            screen = .home
            mainWindow?.makeKeyAndOrderFront(nil)
        }
    }

    private func presentAlert(_ title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private func importVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, UTType(filenameExtension: "webm") ?? .movie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // A Smoooth recording is "<base>-screen.mp4" with sibling "<base>.json" metadata
        // and optional "<base>-webcam.mp4". Resolve those so opening a recording restores
        // its cursor metadata + webcam; otherwise fall back to "<video>.json".
        let fm = FileManager.default
        var metadataURL = url.deletingPathExtension().appendingPathExtension("json")
        var webcamURL: URL? = nil
        let name = url.lastPathComponent
        if name.hasSuffix("-screen.mp4") {
            let base = String(name.dropLast("-screen.mp4".count))
            let dir = url.deletingLastPathComponent()
            let sibMeta = dir.appendingPathComponent(base + ".json")
            if fm.fileExists(atPath: sibMeta.path) { metadataURL = sibMeta }
            let sibCam = dir.appendingPathComponent(base + "-webcam.mp4")
            if fm.fileExists(atPath: sibCam.path) { webcamURL = sibCam }
        }
        Task {
            await model.loadProject(videoURL: url, metadataURL: metadataURL, webcamVideoURL: webcamURL)
            screen = .editor
        }
    }
}

// HomeView lives in HomeView.swift (bold marketing surface + signature hero).

#Preview { ContentView() }
