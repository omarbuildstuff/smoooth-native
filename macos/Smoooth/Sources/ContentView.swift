import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SmooothCore

struct ContentView: View {
    @State private var model = EditorModel()
    @StateObject private var recorder = RecordingCoordinator()
    @State private var screen: Screen = .home

    enum Screen { case home, recorder, editor }

    private var theme: Theme { Theme(model.mode) }

    var body: some View {
        Group {
            switch screen {
            case .home:
                HomeView(onImport: importVideo, onRecord: { screen = .recorder })
            case .recorder:
                RecorderView(coordinator: recorder,
                             onFinished: { result in loadRecording(result) },
                             onCancel: { screen = .home })
            case .editor:
                EditorView(model: model)
            }
        }
        .frame(minWidth: 1100, minHeight: 740)
        .environment(\.theme, theme)
        .preferredColorScheme(model.mode == "dark" ? .dark : .light)
    }

    private func loadRecording(_ result: RecordingResult) {
        Task {
            await model.loadProject(videoURL: result.screenVideoURL,
                                    metadataURL: result.metadataURL,
                                    webcamVideoURL: result.webcamVideoURL)
            screen = .editor
        }
    }

    private func importVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, UTType(filenameExtension: "webm") ?? .movie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let metadataURL = url.deletingPathExtension().appendingPathExtension("json")
        Task {
            await model.loadProject(videoURL: url, metadataURL: metadataURL, webcamVideoURL: nil)
            screen = .editor
        }
    }
}

// HomeView lives in HomeView.swift (bold marketing surface + signature hero).

#Preview { ContentView() }
