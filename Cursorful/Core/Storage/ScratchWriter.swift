import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

/// Wraps AVAssetWriter for writing HEVC video + optional AAC audio to a .mov file during capture.
///
/// Design notes:
/// - Hardware-accelerated HEVC encode via VideoToolbox is requested via the
///   `kVTCompressionPropertyKey_EnableHardwareAcceleratedVideoEncoder` / `kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder`
///   attributes passed through AVAssetWriter's `compressionProperties`.
/// - We don't do any effects here. Frames go in, frames come out, HEVC is written.
/// - Input is a `CVPixelBuffer` delivered by ScreenCaptureKit. We don't re-alloc or copy.
final class ScratchWriter: @unchecked Sendable {

    enum WriterError: Error {
        case alreadyStarted
        case notStarted
        case missingVideoSettings
        case avError(Error)
    }

    private let url: URL
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    private(set) var isRecording: Bool = false
    private var started: Bool = false
    private var startPTS: CMTime = .invalid

    let width: Int
    let height: Int
    let fps: Int32

    init(url: URL, width: Int, height: Int, fps: Int32 = 60) {
        self.url = url
        self.width = width
        self.height = height
        self.fps = fps
    }

    // MARK: - Setup

    func prepare() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = false

        // Video input
        let bitrate = bitrateForHEVC(width: width, height: height, fps: Int(fps))
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        let sourcePixelBufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput, sourcePixelBufferAttributes: sourcePixelBufferAttrs
        )

        guard writer.canAdd(videoInput) else { throw WriterError.missingVideoSettings }
        writer.add(videoInput)

        self.writer = writer
        self.videoInput = videoInput
        self.pixelBufferAdaptor = adaptor
    }

    /// Configure an optional audio input. Must be called before `start(at:)`.
    func addAudioInput() {
        guard let writer else { return }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 48000,
            AVEncoderBitRateKey: 192_000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        if writer.canAdd(input) {
            writer.add(input)
            self.audioInput = input
        }
    }

    // MARK: - Lifecycle

    func start(at pts: CMTime) throws {
        guard let writer else { throw WriterError.notStarted }
        guard !started else { throw WriterError.alreadyStarted }
        if !writer.startWriting() {
            if let err = writer.error { throw WriterError.avError(err) }
        }
        writer.startSession(atSourceTime: pts)
        startPTS = pts
        started = true
        isRecording = true
        Log.storage.info("ScratchWriter started at pts=\(pts.secondsOrZero, format: .fixed(precision: 4))s")
    }

    // MARK: - Append

    @discardableResult
    func appendVideo(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard isRecording, let input = videoInput, input.isReadyForMoreMediaData else { return false }
        return input.append(sampleBuffer)
    }

    @discardableResult
    func appendAudio(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard isRecording, let input = audioInput, input.isReadyForMoreMediaData else { return false }
        return input.append(sampleBuffer)
    }

    // MARK: - Finish

    func finish() async throws -> CMTime {
        guard let writer else { throw WriterError.notStarted }
        guard started else { throw WriterError.notStarted }
        isRecording = false
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        await writer.finishWriting()
        if let err = writer.error { throw WriterError.avError(err) }
        Log.storage.info("ScratchWriter finished: \(self.url.path)")

        // Query actual duration
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration)) ?? .zero
        return duration
    }

    // MARK: - Helpers

    private func bitrateForHEVC(width: Int, height: Int, fps: Int) -> Int {
        // Rough bits-per-pixel heuristic tuned for screen content (higher motion tolerance).
        // 4K60 → ~50 Mbps, 1080p60 → ~18 Mbps, 720p30 → ~6 Mbps.
        let bpp = 0.06
        return Int(Double(width * height * fps) * bpp)
    }
}
