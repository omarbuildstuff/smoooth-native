import SwiftUI
import AppKit
import SmooothCore

struct ExportView: View {
    @Bindable var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    @State private var resolution = "1080p"
    @State private var fps = 30
    @State private var format: ExportFormat = .mp4
    @State private var progress: Double = 0
    @State private var isExporting = false
    @State private var statusMessage: String?
    @State private var exporter = VideoExporter()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export").font(.title2.bold())

            if isExporting {
                ProgressView(value: progress) { Text("Exporting… \(Int(progress * 100))%") }
                Button("Cancel") { exporter.cancel() }
            } else {
                Picker("Resolution", selection: $resolution) {
                    Text("720p").tag("720p"); Text("1080p").tag("1080p"); Text("2K").tag("2k")
                }
                Picker("Frame rate", selection: $fps) {
                    Text("24 fps").tag(24); Text("30 fps").tag(30); Text("60 fps").tag(60)
                }
                Picker("Format", selection: $format) {
                    Text("MP4 (H.264)").tag(ExportFormat.mp4); Text("GIF").tag(ExportFormat.gif)
                }
                if let statusMessage { Text(statusMessage).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("Cancel") { dismiss() }
                    Spacer()
                    Button("Export…") { startExport() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.videoURL == nil)
                }
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func startExport() {
        guard let mainURL = model.videoURL else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Smoooth-export.\(format.rawValue)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }

        let settings = ExportSettings(resolution: resolution, fps: fps, format: format)
        let job = VideoExporter.Job(
            mainVideoURL: mainURL, webcamVideoURL: model.webcamVideoURL, model: model.sceneModel,
            backgroundImage: model.backgroundImage, cursorBitmaps: model.cursorBitmaps,
            duration: model.duration, cutRegions: model.cutRegions, speedRegions: model.speedRegions,
            aspectRatio: model.aspectRatio, settings: settings, outputURL: outputURL)

        isExporting = true
        progress = 0
        let exporterRef = exporter
        Task {
            do {
                _ = try await exporterRef.export(job) { p in
                    Task { @MainActor in self.progress = p }
                }
                await MainActor.run {
                    isExporting = false
                    statusMessage = "Saved to \(outputURL.lastPathComponent)"
                    NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    statusMessage = "Export failed: \(error)"
                }
            }
        }
    }
}
