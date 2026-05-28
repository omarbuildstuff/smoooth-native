import AVFoundation
import CoreGraphics
import Foundation

/// Exact-frame random access into a source video, used by the seek-driven export
/// loop (mirrors the renderer's zero-tolerance `video.currentTime` seeking).
public final class FrameSource: @unchecked Sendable {
    private let asset: AVURLAsset
    private let generator: AVAssetImageGenerator

    public init(url: URL) {
        asset = AVURLAsset(url: url)
        generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = true
    }

    /// Natural pixel size of the first video track.
    public func videoSize() async throws -> SizeD {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let applied = size.applying(transform)
        return SizeD(width: abs(applied.width), height: abs(applied.height))
    }

    public func duration() async throws -> Double {
        try await CMTimeGetSeconds(asset.load(.duration))
    }

    /// Nominal frame rate of the first video track (falls back to 30).
    public func nominalFrameRate() async -> Double {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let fps = try? await track.load(.nominalFrameRate), fps > 0 else { return 30 }
        return Double(fps)
    }

    public func hasAudio() async -> Bool {
        ((try? await asset.loadTracks(withMediaType: .audio))?.isEmpty == false)
    }

    /// Exact frame at the given source time (seconds).
    public func image(at seconds: Double) async -> CGImage? {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }
}
