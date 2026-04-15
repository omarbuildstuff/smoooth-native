import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Decodes frames from a video file on demand. Optimized for two workflows:
///   1. Seek to an arbitrary time, decode one frame (for scrubbing).
///   2. Linear playback starting from a seek point (for preview playback / export).
///
/// Internal: wraps AVAssetReader with a fresh reader per seek because AVAssetReader doesn't support
/// seek. Creating a reader is cheap for MP4/HEVC.
actor FrameProvider {

    let asset: AVAsset
    private(set) var duration: CMTime = .zero
    private(set) var naturalSize: CGSize = .zero
    private(set) var nominalFrameRate: Float = 60

    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var currentTime: CMTime = .zero

    init(url: URL) {
        self.asset = AVURLAsset(url: url)
    }

    func prepare() async throws {
        self.duration = try await asset.load(.duration)
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            self.naturalSize = try await track.load(.naturalSize)
            self.nominalFrameRate = try await track.load(.nominalFrameRate)
        }
    }

    /// Seek to `time` and return the first decoded pixel buffer at or after it.
    func frame(at time: CMTime) async throws -> CVPixelBuffer? {
        try resetReader(startAt: time, endAt: duration)
        return nextPixelBuffer()
    }

    /// Starts linear reading from `start`. Subsequent calls to `nextFrame()` return sequential frames.
    func startLinearRead(from start: CMTime, to end: CMTime? = nil) throws {
        try resetReader(startAt: start, endAt: end ?? duration)
    }

    /// Next frame in linear reading mode. Returns nil at end of range.
    func nextFrame() -> CVPixelBuffer? { nextPixelBuffer() }

    // MARK: - Internals

    private func resetReader(startAt start: CMTime, endAt end: CMTime) throws {
        reader?.cancelReading()
        reader = nil
        output = nil

        let r = try AVAssetReader(asset: asset)
        r.timeRange = CMTimeRange(start: start, end: end)
        guard let track = asset.tracks(withMediaType: .video).first else { return }

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        out.alwaysCopiesSampleData = false
        if r.canAdd(out) { r.add(out) }

        if !r.startReading() {
            if let err = r.error { throw err }
        }
        self.reader = r
        self.output = out
        self.currentTime = start
    }

    private func nextPixelBuffer() -> CVPixelBuffer? {
        guard let output, let sb = output.copyNextSampleBuffer() else { return nil }
        currentTime = CMSampleBufferGetPresentationTimeStamp(sb)
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return nil }
        return pb
    }
}
