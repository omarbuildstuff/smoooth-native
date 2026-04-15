import Combine
import SwiftUI
import UniformTypeIdentifiers

struct ExportSheet: View {
    let package: RecordingPackage
    let project: Project
    @Environment(\.dismiss) private var dismiss
    @State private var preset: ExportPreset = .defaultPreset
    @StateObject private var exporter = ExporterHolder()
    @State private var saveURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text("Export Recording").font(Typography.header.weight(.bold))

            Picker("Preset", selection: $preset) {
                ForEach(ExportPreset.presets) { p in
                    Text(p.label).tag(p)
                }
            }
            .pickerStyle(.menu)

            if case .running = exporter.state {
                ProgressView(value: exporter.progress)
                Text(String(format: "%.0f%%", exporter.progress * 100))
                    .font(Typography.small).foregroundStyle(.secondary)
            }
            if case .finished(let url) = exporter.state {
                HStack {
                    Image(systemName: Icons.check).foregroundStyle(.green)
                    Text("Exported to").font(Typography.small)
                    Button(url.lastPathComponent) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(.link)
                }
            }
            if case .failed(let msg) = exporter.state {
                HStack {
                    Image(systemName: Icons.warning).foregroundStyle(.orange)
                    Text(msg).font(Typography.small).foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
                Button("Export") {
                    let saved = savePanelURL()
                    if let saved {
                        saveURL = saved
                        exporter.start(package: package, project: project, preset: preset, url: saved)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(exporter.state == .running)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 520)
    }

    private func savePanelURL() -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "Cursorful-\(package.id.uuidString.prefix(8)).mp4"
        let resp = panel.runModal()
        return resp == .OK ? panel.url : nil
    }
}

@MainActor
final class ExporterHolder: ObservableObject {
    @Published var progress: Double = 0
    @Published var state: Exporter.State = .idle
    private var exporter: Exporter?
    private var cancellables: Set<AnyCancellable> = []

    func start(package: RecordingPackage, project: Project, preset: ExportPreset, url: URL) {
        let ex = Exporter(package: package, project: project, preset: preset, outputURL: url)
        exporter = ex
        // Mirror progress/state
        ex.$progress.assign(to: &$progress)
        ex.$state.assign(to: &$state)
        Task { await ex.run() }
    }
}
