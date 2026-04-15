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
/// Design decisions (after code review):
/// - Writer appends run on a dedicated serial queue (`writerQueue`) — NOT on MainActor.
///   Capture callbacks do only a `writerQueue.async` hop; MainActor never touches the hot path.
/// - `EventClock.anchor(toFirstFramePTSSeconds:)` is called with the first frame's PTS, making
///   the session zero-point match the first video frame. Cursor/click samples taken before the
///   first frame get clamped to t=0 at read time (tiny epsilon — SCStream startup < 500ms).
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

    // MARK: - Public callbacks

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
    private var metaInFlight: RecordingSessionMeta?

    /// Serial queue owning writer calls + first-frame anchor. Keeps capture off MainActor.
    private let writerQueue = DispatchQueue(label: "com.cursorful.capture.writer", qos: .userInteractive)

    init(store: RecordingStore) {
        self.store = store
    }

    // MARK: - Start

    func startRecording(mode: Mode = .fullscreen) async {
        guard state == .idle else { return }
        state = .preparing

        do {
            let display = try await ScreenCapturer.primaryDisplay()

            let source: ScreenCapturer.SourceKind
            switch mode {
            case .fullscreen:
                source = .display(display)
            case .window:
                let content = try await ScreenCapturer.shareableContent()
                let ourPid = ProcessInfo.processInfo.processIdentifier
                if let front = content.windows.first(where: {
                    $0.isOnScreen && $0.owningApplication?.processID != ourPid
                }) {
                    source = .window(front)
                } else {
                    source = .display(display)
                }
            }

            let pkg = store.createPackage()
            currentPackage = pkg

            let config = ScreenCapturer.Configuration.defaultFor(source, fps: 60, audio: false)

            // Writer (not started yet — awaits first-frame anchor)
            let writer = ScratchWriter(url: pkg.videoURL, width: config.width, height: config.height, fps: config.fps)
            try writer.prepare()
            self.writer = writer
            box.writer = writer

            // Clock — not anchored until first frame lands
            let clock = EventClock()
            self.clock = clock
            box.clock = clock

            // Event log
            let eventWriter = try EventLogWriter(url: pkg.eventsURL)
            self.eventWriter = eventWriter

            // Cursor tracker — bound to recorded-display origin for multi-monitor correctness
            let screenFrame = screenFrameForDisplay(display)
            let tracker = CursorTracker(clock: clock, displayFrame: screenFrame)
            tracker.onCursorSample = { [weak eventWriter] sample in eventWriter?.writeCursor(sample) }
            tracker.onClick        = { [weak eventWriter] click  in eventWriter?.writeClick(click) }
            tracker.start()
            self.cursorTracker = tracker

            // Screen capture
            let capturer = ScreenCapturer()
            // IMPORTANT: these callbacks run on SCK's background queue.
            // We forward to writerQueue (NOT MainActor).
            capturer.onVideoSampleBuffer = { [weak self] sampleBuffer in
                self?.enqueueVideo(sampleBuffer)
            }
            capturer.onStopError = { [weak self] err in
                Task { @MainActor in self?.handleFatal(err) }
            }
            try await capturer.start(source: source, config: config)
            self.capturer = capturer

            // Meta — sessionStartSeconds will be updated after anchor lands
            let meta = RecordingSessionMeta(
                id: pkg.id,
                startedAt: Date(),
                displayID: display.displayID,
                sourceWidth: config.width,
                sourceHeight: config.height,
                pixelScale: 2.0,
                fps: config.fps,
                codec: "hevc",
                clockSessionStartSeconds: 0, // written at stop time
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

        // Drain any pending writer-queue work before finishing the writer.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writerQueue.async { cont.resume() }
        }

        let finalDuration: CMTime
        do {
            finalDuration = try await writer?.finish() ?? .zero
        } catch {
            Log.capture.error("Writer finish failed: \(error.localizedDescription)")
            finalDuration = .zero
        }

        if var meta = metaInFlight, let pkg = currentPackage {
            meta.duration = finalDuration
            meta.clockSessionStartSeconds = clock?.sessionStartSeconds ?? 0
            try? pkg.writeMeta(meta)
        }

        let pkg = currentPackage
        await teardown()
        state = .idle
        if let pkg { onFinish?(pkg) }
    }

    // MARK: - Sample handling — off MainActor

    nonisolated private func enqueueVideo(_ sampleBuffer: CMSampleBuffer) {
        // Retain via CFRetain is unnecessary — Swift captures hold the reference.
        writerQueue.async { [weak self] in
            self?.handleVideoOnWriterQueue(sampleBuffer)
        }
    }

    /// Runs exclusively on `writerQueue`. Reads writer/clock through a nonisolated Sendable box.
    nonisolated private func handleVideoOnWriterQueue(_ sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ptsSeconds = pts.secondsOrZero
        guard let writer = box.writer, let clock = box.clock else { return }

        if !writer.isRecording {
            clock.anchor(toFirstFramePTSSeconds: ptsSeconds)
            do {
                try writer.startSession(anchorPTS: pts)
            } catch {
                Log.capture.error("Writer startSession failed: \(error.localizedDescription)")
                return
            }
        }
        _ = writer.appendVideo(sampleBuffer)
    }

    /// Sendable box holding live capture refs that the writerQueue (and any other nonisolated
    /// callback) can read without hopping back to MainActor. Mutated only on MainActor during
    /// start/stop, which strictly happen-before any writerQueue execution.
    private let box = CaptureBox()

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
        box.writer = nil
        box.clock = nil
    }

    private func handleFatal(_ error: Error) {
        Log.capture.error("Fatal capture error: \(error.localizedDescription)")
        Task { await self.stopRecording() }
    }

    // MARK: - Helpers

    private func screenFrameForDisplay(_ display: SCDisplay) -> CGRect {
        // Match SCDisplay to an NSScreen by displayID so we can map NSEvent.mouseLocation correctly.
        for screen in NSScreen.screens {
            if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               CGDirectDisplayID(num.uint32Value) == display.displayID {
                return screen.frame
            }
        }
        // Fallback: use the main screen.
        return NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: display.width, height: display.height)
    }
}

// MARK: - Bundle version helper

private extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0"
    }
}

// MARK: - Sendable storage box

/// Holds live capture refs accessible from any queue. Mutated only on MainActor during
/// startRecording/teardown — those mutations strictly happen-before any nonisolated read on
/// the writerQueue (we drain that queue before teardown completes).
final class CaptureBox: @unchecked Sendable {
    var writer: ScratchWriter?
    var clock: EventClock?
}
