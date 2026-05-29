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

    private var theme: Theme { Theme(model.mode) }

    var body: some View {
        VStack(spacing: 0) {
            if isExporting {
                progressView
            } else {
                settingsHeader
                settingsBody
                footer
            }
        }
        .frame(width: 460)
        .background(theme.card)
        .environment(\.theme, theme)
        .preferredColorScheme(model.mode == "dark" ? .dark : .light)
    }

    // MARK: - Header

    private var settingsHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: theme.radiusMd, style: .continuous).fill(theme.primary.opacity(0.12))
                Image(systemName: "square.and.arrow.up").font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.primary)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Export Settings").font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.foreground)
                Text("Configure your export options").font(.system(size: 12)).foregroundStyle(theme.mutedForeground)
            }
            Spacer()
        }
        .padding(20)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
    }

    // MARK: - Body

    private var settingsBody: some View {
        VStack(spacing: 16) {
            settingRow("Format") {
                Picker("", selection: $format) {
                    Text("MP4 (Video)").tag(ExportFormat.mp4)
                    Text("GIF (Animation)").tag(ExportFormat.gif)
                }.labelsHidden()
            }
            settingRow("Resolution") {
                Picker("", selection: $resolution) {
                    Text("HD (720p)").tag("720p"); Text("Full HD (1080p)").tag("1080p"); Text("2K (1440p)").tag("2k")
                }.labelsHidden()
            }
            settingRow("Frame rate") {
                Picker("", selection: $fps) {
                    Text("24 FPS").tag(24); Text("30 FPS").tag(30); Text("60 FPS").tag(60)
                }.labelsHidden()
            }

            // Estimated duration pill
            HStack {
                Text("Estimated Duration").font(.system(size: 13, weight: .medium)).foregroundStyle(theme.foreground)
                Spacer()
                Text(durationLabel(model.exportDuration))
                    .font(.system(size: 13, weight: .bold).monospacedDigit()).foregroundStyle(theme.primary)
            }
            .padding(12)
            .background(theme.muted.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusMd, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: theme.radiusMd, style: .continuous).strokeBorder(theme.border, lineWidth: 1)
            )

            if let statusMessage {
                Text(statusMessage).font(.system(size: 12)).foregroundStyle(theme.mutedForeground)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(SoftButtonStyle(theme: theme))
            Button("Start Export") { startExport() }
                .buttonStyle(PremiumButtonStyle(theme: theme))
                .keyboardShortcut(.defaultAction)
                .disabled(model.videoURL == nil)
        }
        .padding(16)
        .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
    }

    // MARK: - Progress

    private var progressView: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(theme.primary.opacity(0.12))
                ProgressView().controlSize(.large).tint(theme.primary)
            }
            .frame(width: 64, height: 64)
            .padding(.top, 32)

            Text("Exporting…").font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.foreground)
                .padding(.top, 16)
            Text("Please wait while we process your video.")
                .font(.system(size: 12)).foregroundStyle(theme.mutedForeground)
                .padding(.top, 4)

            // progress bar
            ZStack(alignment: .leading) {
                GeometryReader { g in
                    Capsule().fill(theme.muted).frame(height: 8)
                    Capsule().fill(theme.primary).frame(width: g.size.width * progress, height: 8)
                }
            }
            .frame(height: 8)
            .padding(.horizontal, 32)
            .padding(.top, 28)

            Text("\(Int(progress * 100))%")
                .font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(theme.primary)
                .padding(.top, 12)

            Button("Cancel") { exporter.cancel() }
                .buttonStyle(SoftButtonStyle(theme: theme))
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func settingRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 16) {
            Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.foreground)
                .frame(width: 110, alignment: .leading)
            content().frame(maxWidth: .infinity)
        }
    }

    private func durationLabel(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let m = Int(s) / 60, sec = Int(s) % 60
        return String(format: "%d:%02d", m, sec)
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
            customCursor: model.customCursor,
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
