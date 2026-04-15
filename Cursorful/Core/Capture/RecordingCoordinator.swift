import AppKit
import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

/// Top-level controller that drives a recording from start to finish.
///
/// Lifecycle:
///   idle → preparing → recording → stopping → finalizing → idle
///
/// On stop the coordinator produces a finalized `RecordingPackage` and emits it via `onFinish`.
@MainActor
final class RecordingCoordinator: ObservableObject {

    enum Mode { case fullscreen, window }

    enum State: Equatable {
        case idle
        case preparing
        case recording(startedAt: Date)
        case paused
        case stopping
        case finalizing
    }

    // MARK: - Public callbacks (set by AppDelegate / views)

    var onStateChange: ((State) -> Void)?
    var onFinish: ((RecordingPackage) -> Void)?

    @Published private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }

    // MARK: - Dependencies

    private let store: RecordingStore

    // MARK: - Per-session state

    private var currentPackage: RecordingPackage?
    private var capturer: ScreenCapturer?
    private var writer: ScratchWriter?
    private var eventWriter: EventLogWriter?
    private var cursorTracker: CursorTracker?
    private var clock: EventClock?
    private var startedAt: Date?

    /// Full meta being built during the session (completed at stop).
    private var metaInFlight: RecordingSessionMeta?

    init(store: RecordingStore) {
        self.store = store
    }

    // MARK: - Start

    func startRecording(mode: Mode = .fullscreen) async {
        guard state == .idle else { return }
        state = .preparing

        do {
            let display = try await ScreenCapturer.primaryDisplay()

            // Resolve source
            let source: ScreenCapturer.SourceKind
            switch mode {
            case .fullscreen:
                source = .display(display)
            case .window:
                let content = try await ScreenCapturer.shareableContent()
                // Naive heuristic: front-most on-screen window that isn't us.
                let ourPid = ProcessInfo.processInfo.processIdentifier
                if let front = content.windows.first(where: {
                    $0.isOnScreen && $0.owningApplication?.processID != ourPid
                }) {
                    source = .window(front)
                } else {
                    source = .display(display)
                }
            }

            // Package & files
            let pkg = store.createPackage()
            currentPackage = pkg

            // Configuration based on source (always source-native pixels)
            let config = ScreenCapturer.Configuration.defaultFor(source, fps: 60, audio: false)

            // Writer
            let writer = ScratchWriter(url: pkg.videoURL, width: config.width, height: config.height, fps: config.fps)
            try writer.prepare()
            self.writer = writer

            // Clock
            let clock = EventClock()
            self.clock = clock

            // Event log
            let eventWriter = try EventLogWriter(url: pkg.eventsURL)
            self.eventWriter = eventWriter

            // Cursor tracker
            let tracker = CursorTracker(clock: clock)
            tracker.onCursorSample = { [weak eventWriter] sample in eventWriter?.writeCursor(sample) }
            tracker.onClick        = { [weak eventWriter] click  in eventWriter?.writeClick(click) }
            tracker.start()
            self.cursorTracker = tracker

            // Screen capture
            let capturer = ScreenCapturer()
            capturer.onVideoSampleBuffer = { [weak self] sampleBuffer in
                self?.handleVideoSample(sampleBuffer)
            }
            capturer.onStopError = { [weak self] err in
                Task { @MainActor in self?.handleFatal(err) }
            }
            try await capturer.start(source: source, config: config)
            self.capturer = capturer

            // Meta
            let meta = RecordingSessionMeta(
                id: pkg.id,
                startedAt: Date(),
                displayID: display.displayID,
                sourceWidth: config.width,
                sourceHeight: config.height,
                pixelScale: 2.0,
                fps: config.fps,
                codec: "hevc",
                clockSessionStartSeconds: clock.sessionStartSeconds,
                duration: .zero,
                appVersion: Bundle.main.shortVersion
            )
            self.metaInFlight = meta

            startedAt = Date()
            state = .recording(startedAt: startedAt!)
            Log.capture.info("Recording started \(pkg.url.lastPathComponent)")
        } catch {
            Log.capture.error("Failed to start recording: \(error.localizedDescription)")
            await teardown()
            state = .idle
        }
    }

    // MARK: - Stop

    func stopRecording() async {
        switch state {
        case .recording, .paused:
            state = .stopping
        default:
            return
        }

        await capturer?.stop()
        cursorTracker?.stop()
        eventWriter?.close()

        state = .finalizing

        let finalDuration: CMTime
        do {
            finalDuration = try await writer?.finish() ?? .zero
        } catch {
            Log.capture.error("Writer finish failed: \(error.localizedDescription)")
            finalDuration = .zero
        }

        // Persist meta
        if var meta = metaInFlight, let pkg = currentPackage {
            meta.duration = finalDuration
            try? pkg.writeMeta(meta)
        }

        let pkg = currentPackage
        await teardown()
        state = .idle
        if let pkg { onFinish?(pkg) }
    }

    // MARK: - Sample handling (background queue)

    nonisolated private func handleVideoSample(_ sampleBuffer: CMSampleBuffer) {
        // Start writer session on the first frame so our timeline zero matches the first frame.
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        Task { @MainActor [weak self] in
            guard let self, let writer = self.writer else { return }
            if !writer.isRecording {
                do {
                    try writer.start(at: pts)
                } catch {
                    Log.capture.error("Writer start failed: \(error.localizedDescription)")
                    return
                }
            }
            writer.appendVideo(sampleBuffer)
        }
    }

    // MARK: - Cleanup

    private func teardown() async {
        capturer = nil
        writer = nil
        cursorTracker = nil
        eventWriter = nil
        clock = nil
        metaInFlight = nil
        currentPackage = nil
        startedAt = nil
    }

    private func handleFatal(_ error: Error) {
        Log.capture.error("Fatal capture error: \(error.localizedDescription)")
        Task { await self.stopRecording() }
    }
}

// MARK: - Bundle version helper

private extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0"
    }
}
