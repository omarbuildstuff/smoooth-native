import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SmooothCore

struct ContentView: View {
    @State private var model = EditorModel()
    @StateObject private var recorder = RecordingCoordinator()
    @State private var screen: Screen = .home

    enum Screen { case home, recorder, editor }

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

struct HomeView: View {
    let onImport: () -> Void
    let onRecord: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "video.circle.fill").font(.system(size: 64)).foregroundStyle(.tint)
            Text("Smoooth").font(.system(size: 40, weight: .bold))
            Text("Cinematic screen recording for macOS").foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Button { onRecord() } label: {
                    Label("New Recording", systemImage: "record.circle")
                        .frame(width: 160, height: 40)
                }.buttonStyle(.borderedProminent)
                Button { onImport() } label: {
                    Label("Open Video…", systemImage: "folder")
                        .frame(width: 160, height: 40)
                }
            }
            Text("Recording uses ScreenCaptureKit + cinematic auto-zoom.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

#Preview { ContentView() }
