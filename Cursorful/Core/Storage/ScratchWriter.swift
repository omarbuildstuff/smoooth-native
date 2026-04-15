import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

/// Wraps AVAssetWriter for writing HEVC video + optional AAC audio to a .mov file during capture.
///
/// Design notes:
/// - Session time in the output file is **zero-based**: `startSession(atSourceTime: .zero)` and
///   every appended sample buffer is retimed `pts - anchorPTS`. The saved file's timeline starts
///   at 0 and matches the event log's session-relative timestamps.
/// - Input is a `CVPixelBuffer` delivered by ScreenCaptureKit. We retime via
///   `CMSampleBufferCreateCopyWithNewTiming` (zero-copy — only the timing info changes).
/// - Not thread-safe by itself; owner should serialize calls on a dedicated writer queue.
final class ScratchWriter: @unchecked Sendable {

    enum WriterError: Error {
        case alreadyStarted
        case notStarted
        case missingVideoSettings
        case retimingFailed(OSStatus)
        case avError(Error)
    }

    private let url: URL
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    private(set) var isRecording: Bool = false
    private var started: Bool = false

    /// The host-time PTS (seconds since mach boot) of the first video frame — this is the session
    /// zero-point. All subsequent samples are retimed relative to this.
    private(set) var anchorPTS: CMTime = .invalid

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

    /// Configure an optional audio input. Must be called before `startSession(anchorPTS:)`.
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

    /// Start the writer session at time zero; `anchorPTS` is the first-frame host PTS used to
    /// rebase all subsequent samples.
    func startSession(anchorPTS: CMTime) throws {
        guard let writer else { throw WriterError.notStarted }
        guard !started else { throw WriterError.alreadyStarted }
        if !writer.startWriting() {
            if let err = writer.error { throw WriterError.avError(err) }
        }
        writer.startSession(atSourceTime: .zero)
        self.anchorPTS = anchorPTS
        started = true
        isRecording = true
        Log.storage.info("ScratchWriter session=0, anchorPTS=\(anchorPTS.secondsOrZero, format: .fixed(precision: 4))s")
    }

    // MARK: - Append (PTS-rebased)

    @discardableResult
    func appendVideo(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard isRecording, let input = videoInput, input.isReadyForMoreMediaData else { return false }
        guard let retimed = retime(sampleBuffer) else { return false }
        return input.append(retimed)
    }

    @discardableResult
    func appendAudio(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard isRecording, let input = audioInput, input.isReadyForMoreMediaData else { return false }
        guard let retimed = retime(sampleBuffer) else { return false }
        return input.append(retimed)
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

        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration)) ?? .zero
        return duration
    }

    // MARK: - Retiming

    /// Rebase the sample buffer's PTS to `(pts - anchorPTS)`. Decode timestamps (if present) are
    /// rebased too. Duration is preserved.
    private func retime(_ sb: CMSampleBuffer) -> CMSampleBuffer? {
        guard CMTIME_IS_VALID(anchorPTS) else { return nil }
        let origPTS = CMSampleBufferGetPresentationTimeStamp(sb)
        let origDTS = CMSampleBufferGetDecodeTimeStamp(sb)
        let origDur = CMSampleBufferGetDuration(sb)

        var timingInfo = CMSampleTimingInfo(
            duration: origDur,
            presentationTimeStamp: CMTimeSubtract(origPTS, anchorPTS),
            decodeTimeStamp: CMTIME_IS_VALID(origDTS) ? CMTimeSubtract(origDTS, anchorPTS) : .invalid
        )

        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sb,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleBufferOut: &out
        )
        guard status == noErr else {
            Log.storage.error("Sample retiming failed: \(status)")
            return nil
        }
        return out
    }

    // MARK: - Helpers

    private func bitrateForHEVC(width: Int, height: Int, fps: Int) -> Int {
        // 4K60 → ~50 Mbps, 1080p60 → ~18 Mbps, 720p30 → ~6 Mbps.
        let bpp = 0.06
        return Int(Double(width * height * fps) * bpp)
    }
}
