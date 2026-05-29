import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CoreVideo
import AppKit

/// Native screen capture using **ScreenCaptureKit** feeding an **AVAssetWriter**
/// (H.264 via VideoToolbox) — the single clean path that replaces the
/// Electron/ffmpeg/webm pipeline (recording-manager.ts `muxMacScreenWebm` and
/// friends). Captures a whole display, a sub-region, or a window. `showsCursor`
/// is forced off because the editor overlays its own cursor (faithful to the
/// `-draw_mouse 0` / `showsCursor=false` intent in the original).
///
/// Audio: when requested it enables system-audio loopback (`capturesAudio`) and,
/// on macOS 15+, microphone capture (`captureMicrophone`), muxing both into the
/// same `.mp4` writer — no separate files, no post-hoc ffmpeg mux.
///
/// `@unchecked Sendable`: mutable writer/stream state is only touched on the
/// `sampleQueue` / start / stop paths.
public final class ScreenRecorder: NSObject, @unchecked Sendable {

    // MARK: - Configuration captured at start

    private let outputURL: URL
    private let geometry: RecordingGeometry
    private let wantsSystemAudio: Bool
    private let wantsMicrophone: Bool
    /// Specific microphone device to capture; nil uses the system default input.
    private let microphoneDeviceID: String?
    private let fps: Int

    // MARK: - SCKit + writer state

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var micAudioInput: AVAssetWriterInput?

    private let sampleQueue = DispatchQueue(label: "com.smoooth.screenrecorder.samples")
    private let audioQueue = DispatchQueue(label: "com.smoooth.screenrecorder.audio")
    private let micQueue = DispatchQueue(label: "com.smoooth.screenrecorder.mic")

    /// Session-start coordination. The writer session is anchored at the *latest*
    /// first-sample PTS across video + every enabled audio stream, so movie-time 0
    /// is the instant all streams are live. This trims the brief audio-less video
    /// lead caused by microphone hardware warmup (~0.2–0.3s), which otherwise
    /// leaves the mic track sitting late behind video in the muxed file (the
    /// "video early / audio late" desync). Guarded by `startLock`.
    private let startLock = NSLock()
    private var didStartSession = false
    private var anchorPTS: CMTime = .invalid
    private var firstVideoPTS: CMTime = .invalid
    private var firstSystemAudioPTS: CMTime = .invalid
    private var firstMicPTS: CMTime = .invalid
    private var firstVideoWallClock: Double = 0
    /// Fallback: if an enabled audio stream never delivers (e.g. dead device),
    /// start anyway this many seconds after the first video frame.
    private let audioWarmupTimeout: Double = 1.0

    /// Guards the cross-thread scalars (`stopError`, `firstFrameWallClock`) that
    /// are written on the SCKit delegate / sample queues and read on the
    /// MainActor in `stop()` / by the coordinator. A small dedicated lock avoids
    /// any reentrancy hazard with `sampleQueue` (on which `handleVideo` runs).
    private let stateLock = NSLock()
    private var _stopError: Error?
    private var _firstFrameWallClock: Double?

    private var stopError: Error? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _stopError }
        set { stateLock.lock(); _stopError = newValue; stateLock.unlock() }
    }

    /// Absolute wall-clock time (seconds since 1970) of the first written video
    /// frame. The coordinator uses this to rebase mouse-event timestamps so the
    /// first frame sits at ~t=0 (replacing ffprobe `birthtimeMs` sync).
    public private(set) var firstFrameWallClock: Double? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _firstFrameWallClock }
        set { stateLock.lock(); _firstFrameWallClock = newValue; stateLock.unlock() }
    }

    public init(outputURL: URL,
                geometry: RecordingGeometry,
                systemAudio: Bool,
                microphone: Bool,
                microphoneDeviceID: String? = nil,
                fps: Int) {
        self.outputURL = outputURL
        self.geometry = geometry
        self.wantsSystemAudio = systemAudio
        self.wantsMicrophone = microphone
        self.microphoneDeviceID = microphoneDeviceID
        self.fps = fps
        super.init()
    }

    // MARK: - Start

    /// Resolves the capture target, configures the stream + writer, and begins
    /// streaming. Throws on permission / setup failure.
    public func start(source: RecordingSource) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let filter = try makeFilter(for: source, content: content)
        let configuration = makeConfiguration(for: source, content: content)

        try setUpWriter()

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if wantsSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        if wantsMicrophone, #available(macOS 15.0, *) {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: micQueue)
        }
        self.stream = stream

        do {
            try await stream.startCapture()
        } catch {
            throw RecordingError.captureStartFailed(error.localizedDescription)
        }
    }

    // MARK: - Stop

    /// Stops the stream, finalizes the writer, and validates non-empty output.
    /// Returns the finished file URL. Mirrors the careful finalize-then-validate
    /// flow from recording-manager.ts (`screenVideoWriter.finalize()` +
    /// `validateRecordingFiles`).
    @discardableResult
    public func stop() async throws -> URL {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil

        // Mark inputs finished and flush the writer.
        videoInput?.markAsFinished()
        systemAudioInput?.markAsFinished()
        micAudioInput?.markAsFinished()

        if let writer, writer.status == .writing {
            await writer.finishWriting()
        }

        if let stopError {
            throw stopError
        }
        if let writer, writer.status == .failed {
            throw RecordingError.writerSetupFailed(writer.error?.localizedDescription ?? "unknown writer failure")
        }

        // Validate non-empty (the original treated a zero-byte file as fatal).
        let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
        let size = (attrs?[.size] as? Int) ?? 0
        if size == 0 {
            throw RecordingError.emptyOutput(outputURL.lastPathComponent)
        }
        return outputURL
    }

    /// Best-effort teardown that discards the partial file (used by `cancel()`).
    public func abort() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        if let writer, writer.status == .writing {
            // Finish ALL inputs (video + system audio + mic) before flushing, the
            // same way `stop()` does — otherwise a late audio append can land
            // after `finishWriting` and trip an append-after-finish assert.
            videoInput?.markAsFinished()
            systemAudioInput?.markAsFinished()
            micAudioInput?.markAsFinished()
            await writer.finishWriting()
        }
        videoInput = nil
        systemAudioInput = nil
        micAudioInput = nil
        try? FileManager.default.removeItem(at: outputURL)
    }

    // MARK: - Filter construction

    private func makeFilter(for source: RecordingSource, content: SCShareableContent) throws -> SCContentFilter {
        switch source {
        case .fullscreen(let displayID), .area(let displayID, _):
            let display = try resolveDisplay(displayID, content: content)
            // Exclude our own app windows so the recorder/overlay UI never shows
            // up in the capture.
            let ownWindows = content.windows.filter { window in
                window.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
            }
            return SCContentFilter(display: display, excludingWindows: ownWindows)

        case .window(let windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw RecordingError.noWindowAvailable
            }
            return SCContentFilter(desktopIndependentWindow: window)
        }
    }

    private func resolveDisplay(_ displayID: CGDirectDisplayID?, content: SCShareableContent) throws -> SCDisplay {
        if let displayID, let match = content.displays.first(where: { $0.displayID == displayID }) {
            return match
        }
        // Fall back to the main display (mirrors screen.getPrimaryDisplay()).
        let mainID = CGMainDisplayID()
        if let main = content.displays.first(where: { $0.displayID == mainID }) {
            return main
        }
        guard let first = content.displays.first else {
            throw RecordingError.noDisplayAvailable
        }
        return first
    }

    // MARK: - Stream configuration

    private func makeConfiguration(for source: RecordingSource, content: SCShareableContent) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()

        // Output dimensions are the physical-pixel geometry (already even-sized).
        config.width = geometry.width
        config.height = geometry.height

        // We overlay our own cursor in the editor.
        config.showsCursor = false

        // Frame pacing.
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))

        // Pixel format friendly to the H.264 encoder.
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 6

        // Audio.
        if wantsSystemAudio {
            config.capturesAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
        }
        if wantsMicrophone, #available(macOS 15.0, *) {
            config.captureMicrophone = true
            // Honor an explicit device selection; nil falls back to the system
            // default input (SCKit's behavior when the property is unset).
            if let microphoneDeviceID {
                config.microphoneCaptureDeviceID = microphoneDeviceID
            }
        }

        // For an area capture, crop to the selected region. SCStreamConfiguration
        // `sourceRect` is in points (top-left origin) relative to the display;
        // `destinationRect` lets us write at the full pixel size.
        if case let .area(_, rect) = source {
            config.sourceRect = rect
            config.destinationRect = CGRect(x: 0, y: 0, width: geometry.width, height: geometry.height)
            config.scalesToFit = false
        }

        return config
    }

    // MARK: - AVAssetWriter setup

    private func setUpWriter() throws {
        try? FileManager.default.removeItem(at: outputURL)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw RecordingError.writerSetupFailed(error.localizedDescription)
        }

        // Video input — H.264 via VideoToolbox.
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: geometry.width,
            AVVideoHeightKey: geometry.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: estimatedBitrate(),
                AVVideoMaxKeyFrameIntervalKey: max(1, fps * 2),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw RecordingError.writerSetupFailed("cannot add video input")
        }
        writer.add(videoInput)
        self.videoInput = videoInput

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 48_000,
            AVEncoderBitRateKey: 192_000,
        ]

        if wantsSystemAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                self.systemAudioInput = input
            }
        }
        if wantsMicrophone, #available(macOS 15.0, *) {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                self.micAudioInput = input
            }
        }

        guard writer.startWriting() else {
            throw RecordingError.writerSetupFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        self.writer = writer
    }

    private func estimatedBitrate() -> Int {
        // Roughly 0.1 bits per pixel per frame, clamped to a sane band.
        let pixels = geometry.width * geometry.height
        let raw = Int(Double(pixels) * Double(fps) * 0.1)
        return min(max(raw, 4_000_000), 60_000_000)
    }
}

// MARK: - SCStreamDelegate

extension ScreenRecorder: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Record the error so `stop()` can surface it; the coordinator decides
        // how to present it (matching the Electron fatal-error handling). Keep the
        // first error atomically under the lock (two delegate callbacks can race).
        stateLock.lock()
        if _stopError == nil { _stopError = error }
        stateLock.unlock()
    }
}

// MARK: - SCStreamOutput

extension ScreenRecorder: SCStreamOutput {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        switch type {
        case .screen:
            handleVideo(sampleBuffer)
        case .audio:
            handleAudio(sampleBuffer, input: systemAudioInput, stream: .systemAudio)
        default:
            if #available(macOS 15.0, *), type == .microphone {
                handleAudio(sampleBuffer, input: micAudioInput, stream: .microphone)
            }
        }
    }

    /// Identifies which stream a sample arrived on, for first-PTS bookkeeping.
    private enum StreamKind { case video, systemAudio, microphone }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        // Drop frames flagged as not-complete/idle by SCKit (e.g. paused).
        guard isCompleteFrame(sampleBuffer) else { return }
        guard let writer, let videoInput else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard ensureSessionStarted(pts: pts, stream: .video) else { return }
        // Trim the leading audio-less frames: only append at/after the anchor.
        guard pts >= anchor() else { return }

        if writer.status == .writing, videoInput.isReadyForMoreMediaData {
            videoInput.append(sampleBuffer)
        }
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer, input: AVAssetWriterInput?, stream: StreamKind) {
        guard let writer, let input else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard ensureSessionStarted(pts: pts, stream: stream) else { return }
        // Drop pre-anchor audio so every track begins at the common origin.
        guard pts >= anchor() else { return }
        if writer.status == .writing, input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    /// Records the first PTS for `stream` and, once every *enabled* stream has
    /// delivered a sample (or the warmup timeout elapses), starts the writer
    /// session anchored at the latest of those first PTSes. Returns whether the
    /// session has started — callers drop their sample until it has.
    ///
    /// Anchoring at the latest first-sample (rather than the first video frame,
    /// as before) guarantees every track has media at movie-time 0. The mic's
    /// missing warmup audio is genuinely uncaptured, so the correct fix is to
    /// trim the matching leading video, not to shift audio earlier.
    private func ensureSessionStarted(pts: CMTime, stream: StreamKind) -> Bool {
        startLock.lock()
        defer { startLock.unlock() }
        if didStartSession { return true }

        switch stream {
        case .video:
            if !firstVideoPTS.isValid {
                firstVideoPTS = pts
                firstVideoWallClock = Date().timeIntervalSince1970
            }
        case .systemAudio:
            if !firstSystemAudioPTS.isValid { firstSystemAudioPTS = pts }
        case .microphone:
            if !firstMicPTS.isValid { firstMicPTS = pts }
        }

        // Can't anchor before we have at least one video frame.
        guard firstVideoPTS.isValid, let writer else { return false }

        // Only wait on audio streams that were actually wired up (input exists).
        let needSystem = systemAudioInput != nil
        let needMic = micAudioInput != nil
        let haveSystem = !needSystem || firstSystemAudioPTS.isValid
        let haveMic = !needMic || firstMicPTS.isValid
        let timedOut = (Date().timeIntervalSince1970 - firstVideoWallClock) >= audioWarmupTimeout

        guard (haveSystem && haveMic) || timedOut else { return false }

        var a = firstVideoPTS
        if firstSystemAudioPTS.isValid { a = CMTimeMaximum(a, firstSystemAudioPTS) }
        if firstMicPTS.isValid { a = CMTimeMaximum(a, firstMicPTS) }
        anchorPTS = a

        writer.startSession(atSourceTime: a)
        didStartSession = true
        // Wall clock of movie-time 0 (the anchor) — used to rebase mouse events.
        firstFrameWallClock = Date().timeIntervalSince1970
        return true
    }

    /// Common session anchor (latest first-sample PTS); `.invalid` until started.
    private func anchor() -> CMTime {
        startLock.lock(); defer { startLock.unlock() }
        return anchorPTS
    }

    /// SCKit attaches per-frame status; only `.complete` frames carry new pixels.
    private func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
              let attachments = (attachmentsArray as? [[SCStreamFrameInfo: Any]])?.first,
              let rawStatus = attachments[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else {
            // No attachment info — assume the frame is usable.
            return true
        }
        return status == .complete
    }
}
