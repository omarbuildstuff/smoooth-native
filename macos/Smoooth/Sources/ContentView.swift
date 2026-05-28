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

struct HomeView: View {
    @Environment(\.theme) private var theme
    let onImport: () -> Void
    let onRecord: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(theme.primary.opacity(0.12))
                Image(systemName: "video.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(theme.primary)
            }
            .frame(width: 96, height: 96)
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(theme.primary.opacity(0.25), lineWidth: 1)
            )

            VStack(spacing: 8) {
                Text("Smoooth")
                    .font(.system(size: 42, weight: .bold)).tracking(-0.5)
                    .foregroundStyle(theme.foreground)
                Text("Cinematic screen recording for macOS")
                    .font(.system(size: 15)).foregroundStyle(theme.mutedForeground)
            }

            HStack(spacing: 14) {
                Button { onRecord() } label: {
                    Label("New Recording", systemImage: "record.circle")
                        .frame(width: 170)
                }
                .buttonStyle(PremiumButtonStyle(theme: theme, height: 44))

                Button { onImport() } label: {
                    Label("Open Video…", systemImage: "folder")
                        .frame(width: 170)
                }
                .buttonStyle(SoftButtonStyle(theme: theme, height: 44))
            }
            .padding(.top, 4)

            Text("Recording uses ScreenCaptureKit + cinematic auto-zoom.")
                .font(.system(size: 12)).foregroundStyle(theme.mutedForeground.opacity(0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .background(theme.background)
    }
}

#Preview { ContentView() }
