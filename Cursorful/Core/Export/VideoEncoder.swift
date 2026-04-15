import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Writes rendered pixel buffers to an .mp4 file via AVAssetWriter. Handles HEVC and H.264.
final class VideoEncoder {
    private let url: URL
    private let preset: ExportPreset
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var started = false

    enum EncoderError: Error {
        case writerCreationFailed(Error)
        case startWritingFailed(Error)
        case appendFailed
    }

    init(url: URL, preset: ExportPreset) {
        self.url = url
        self.preset = preset
    }

    func prepare() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let codec: AVVideoCodecType = (preset.codec == .hevc) ? .hevc : .h264

            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: preset.bitrate,
                AVVideoExpectedSourceFrameRateKey: preset.fps,
                AVVideoMaxKeyFrameIntervalKey: preset.fps * 2,
            ]
            if preset.codec == .hevc {
                compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
            }

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: preset.width,
                AVVideoHeightKey: preset.height,
                AVVideoCompressionPropertiesKey: compression
            ]
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = false

            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: preset.width,
                kCVPixelBufferHeightKey as String: preset.height,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput, sourcePixelBufferAttributes: attrs
            )
            if writer.canAdd(videoInput) { writer.add(videoInput) }

            self.writer = writer
            self.videoInput = videoInput
            self.adaptor = adaptor
        } catch {
            throw EncoderError.writerCreationFailed(error)
        }
    }

    func start(atSource pts: CMTime) throws {
        guard let writer else { return }
        if !writer.startWriting() {
            if let err = writer.error { throw EncoderError.startWritingFailed(err) }
        }
        writer.startSession(atSourceTime: pts)
        started = true
    }

    func append(pixelBuffer: CVPixelBuffer, pts: CMTime) async throws {
        guard started, let input = videoInput, let adaptor else { return }
        // Wait until the input is ready (cooperative backpressure).
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 1_000_000) // 1ms
        }
        if !adaptor.append(pixelBuffer, withPresentationTime: pts) {
            throw EncoderError.appendFailed
        }
    }

    func finish() async throws {
        guard let writer else { return }
        videoInput?.markAsFinished()
        await writer.finishWriting()
        if let err = writer.error { throw err }
    }

    func pixelBufferPool() -> CVPixelBufferPool? {
        adaptor?.pixelBufferPool
    }
}
