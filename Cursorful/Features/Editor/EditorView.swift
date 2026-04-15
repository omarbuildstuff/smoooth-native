import CoreMedia
import SwiftUI

/// Root editor layout: preview + inspector on top, timeline on bottom.
struct EditorView: View {
    let package: RecordingPackage
    @StateObject private var loader: EditorLoader
    @State private var showingExport = false

    init(package: RecordingPackage) {
        self.package = package
        _loader = StateObject(wrappedValue: EditorLoader(package: package))
    }

    var body: some View {
        Group {
            if let vm = loader.ready {
                loadedContent(vm)
                    .sheet(isPresented: $showingExport) {
                        ExportSheet(package: vm.package, project: vm.model.project)
                            .preferredColorScheme(.dark)
                    }
            } else if let err = loader.error {
                errorView(err)
            } else {
                ProgressView("Loading recording…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black.opacity(0.98))
                    .preferredColorScheme(.dark)
            }
        }
        .task { await loader.load() }
        .onReceive(NotificationCenter.default.publisher(for: .cursorfulExportRequested)) { _ in
            showingExport = true
        }
        .frame(minWidth: 960, minHeight: 560)
    }

    @ViewBuilder
    private func loadedContent(_ vm: EditorViewModel) -> some View {
        VStack(spacing: 0) {
            toolbar(vm: vm)
            HStack(spacing: 0) {
                PreviewPanel(vm: vm)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                InspectorPanel(vm: vm)
                    .frame(width: 280)
                    .background(.black.opacity(0.35))
            }
            .frame(maxHeight: .infinity)
            TimelinePanel(vm: vm)
                .frame(height: 200)
                .background(.black.opacity(0.5))
        }
        .background(.black.opacity(0.98))
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func toolbar(vm: EditorViewModel) -> some View {
        HStack(spacing: Spacing.m) {
            IconButton(systemImage: vm.renderer.isPlaying ? Icons.pause : Icons.play) {
                if vm.renderer.isPlaying { vm.renderer.pause() }
                else                     { vm.renderer.play() }
            }
            Text(timecode(vm.renderer.currentTime, of: vm.model.project.sourceDuration))
                .font(Typography.tc)
                .foregroundStyle(.secondary)
            Spacer()
            Text("Cursorful")
                .font(Typography.body.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                vm.model.save()
            } label: { Label("Save", systemImage: "square.and.arrow.down") }
                .buttonStyle(.bordered)
            Button {
                vm.requestExport()
            } label: { Label("Export", systemImage: Icons.export) }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
        .frame(height: 44)
        .background(.black.opacity(0.6))
    }

    private func errorView(_ err: String) -> some View {
        VStack(spacing: Spacing.m) {
            Image(systemName: Icons.warning).foregroundStyle(.orange).font(.system(size: 24))
            Text("Failed to open recording").font(Typography.header.weight(.bold))
            Text(err).font(Typography.small).foregroundStyle(.secondary)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.98))
        .preferredColorScheme(.dark)
    }

    private func timecode(_ t: CMTime, of total: CMTime) -> String {
        func fmt(_ s: Double) -> String {
            let total = Int(s)
            let m = total / 60, sec = total % 60
            let frac = Int((s - Double(total)) * 100)
            return String(format: "%02d:%02d.%02d", m, sec, frac)
        }
        return "\(fmt(t.secondsOrZero))  /  \(fmt(total.secondsOrZero))"
    }
}

// MARK: - Loader (async bootstrap)

@MainActor
final class EditorLoader: ObservableObject {
    let package: RecordingPackage
    @Published var ready: EditorViewModel?
    @Published var error: String?

    init(package: RecordingPackage) { self.package = package }

    func load() async {
        guard ready == nil, error == nil else { return }
        do {
            let provider = FrameProvider(url: package.videoURL)
            try await provider.prepare()

            // Read meta for source size + duration
            let sourceSize = await provider.naturalSize
            let duration   = await provider.duration

            // Load or create project
            let project: Project
            if let existing = Project.load(from: package) {
                project = existing
            } else {
                // Synthesize a fresh project
                let meta = package.loadMeta() ?? RecordingSessionMeta(
                    id: package.id,
                    startedAt: Date(),
                    displayID: 0,
                    sourceWidth: Int(sourceSize.width),
                    sourceHeight: Int(sourceSize.height),
                    pixelScale: 2.0,
                    fps: 60,
                    codec: "hevc",
                    clockSessionStartSeconds: 0,
                    duration: duration,
                    appVersion: "0.1"
                )
                project = Project.newProject(for: package, meta: meta)
            }

            let model = TimelineModel(package: package, project: project)

            // Auto-generate zoom if no existing track
            if model.project.zoomTrack.isEmpty {
                let events = EventLogReader.read(url: package.eventsURL)
                model.generateAutoZoom(clicks: events.clicks)
            }

            // Metal + renderer
            let ctx = try EffectContext()
            let renderer = try PreviewRenderer(provider: provider, context: ctx)
            renderer.sourceSize = sourceSize
            renderer.zoomEffect.sample = .identity
            renderer.cursorEffect.sourceSize = sourceSize
            renderer.rippleEffect.sourceSize = sourceSize
            let events = EventLogReader.read(url: package.eventsURL)
            renderer.cursorEffect.load(samples: events.cursorSamples)
            renderer.rippleEffect.load(clicks: events.clicks)
            renderer.zoomRegions = model.project.zoomTrack
            renderer.renderMockup = model.project.mockup.enabled
            renderer.renderCursor = model.project.cursor.enabled
            renderer.renderRipples = model.project.cursor.showRipples
            try renderer.rebuildEffects()

            // Seed with the first frame
            await renderer.seek(to: .zero)

            let vm = EditorViewModel(
                package: package,
                model: model,
                renderer: renderer,
                events: events
            )
            self.ready = vm
        } catch {
            self.error = error.localizedDescription
            Log.timeline.error("Editor load failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - ViewModel

@MainActor
final class EditorViewModel: ObservableObject {
    let package: RecordingPackage
    let model: TimelineModel
    @Published var renderer: PreviewRenderer
    let events: EventLogReader.EventLog

    init(package: RecordingPackage,
         model: TimelineModel,
         renderer: PreviewRenderer,
         events: EventLogReader.EventLog) {
        self.package = package
        self.model = model
        self.renderer = renderer
        self.events = events
    }

    func seek(to t: CMTime) { Task { await renderer.seek(to: t) } }

    func requestExport() {
        // Phase 7 wires this to ExportSheet; for now, log.
        Log.export.info("Export requested for \(self.package.url.lastPathComponent)")
        NotificationCenter.default.post(name: .cursorfulExportRequested, object: package)
    }
}

extension Notification.Name {
    static let cursorfulExportRequested = Notification.Name("com.cursorful.exportRequested")
}
