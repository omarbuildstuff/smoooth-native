import Foundation

public enum ExportFormat: String, Sendable, Codable {
    case mp4
    case gif
}

/// Mirrors the renderer's ExportModal settings: resolution key ("720p"/"1080p"/"2k"),
/// fps, and output format.
public struct ExportSettings: Sendable, Codable {
    public var resolution: String
    public var fps: Int
    public var format: ExportFormat

    public init(resolution: String = "1080p", fps: Int = 30, format: ExportFormat = .mp4) {
        self.resolution = resolution; self.fps = fps; self.format = format
    }
}

public enum ExportError: Error, Sendable {
    case cancelled
    case noVideoTrack
    case writerSetupFailed
    case pixelBufferPoolUnavailable
    case frameRenderFailed(Int)
    case writeFailed(String)
}
