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

    private var sessionStarted = false
    private var firstVideoPTS: CMTime = .invalid
    private var stopError: Error?

    /// Absolute wall-clock time (seconds since 1970) of the first written video
    /// frame. The coordinator uses this to rebase mouse-event timestamps so the
    /// first frame sits at ~t=0 (replacing ffprobe `birthtimeMs` sync).
    public private(set) var firstFrameWallClock: Double?

    public init(outputURL: URL,
                geometry: RecordingGeometry,
                systemAudio: Bool,
                microphone: Bool,
                fps: Int) {
        self.outputURL = outputURL
        self.geometry = geometry
        self.wantsSystemAudio = systemAudio
        self.wantsMicrophone = microphone
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
            videoInput?.markAsFinished()
            await writer.finishWriting()
        }
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
        // how to present it (matching the Electron fatal-error handling).
        if stopError == nil { stopError = error }
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
            handleAudio(sampleBuffer, input: systemAudioInput)
        default:
            if #available(macOS 15.0, *), type == .microphone {
                handleAudio(sampleBuffer, input: micAudioInput)
            }
        }
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        // Drop frames flagged as not-complete/idle by SCKit (e.g. paused).
        guard isCompleteFrame(sampleBuffer) else { return }
        guard let writer, let videoInput else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if !sessionStarted {
            sessionStarted = true
            firstVideoPTS = pts
            firstFrameWallClock = Date().timeIntervalSince1970
            writer.startSession(atSourceTime: pts)
        }

        if writer.status == .writing, videoInput.isReadyForMoreMediaData {
            videoInput.append(sampleBuffer)
        }
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer, input: AVAssetWriterInput?) {
        guard let writer, let input else { return }
        // Audio that arrives before the first video frame has nothing to anchor
        // to; drop it so the session timeline starts cleanly on video.
        guard sessionStarted, writer.status == .writing else { return }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
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
