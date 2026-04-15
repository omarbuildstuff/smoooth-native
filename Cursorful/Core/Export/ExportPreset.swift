import CoreGraphics
import CoreMedia
import Foundation

struct ExportPreset: Identifiable, Hashable {
    var id: String { label }
    let label: String
    let width: Int
    let height: Int
    let fps: Int32
    let codec: ExportSettings.Codec
    let aspect: ExportSettings.AspectRatio
    let bitrate: Int

    static let presets: [ExportPreset] = [
        ExportPreset(label: "4K 60fps",    width: 3840, height: 2160, fps: 60, codec: .hevc, aspect: .sixteenNine, bitrate: 45_000_000),
        ExportPreset(label: "4K 30fps",    width: 3840, height: 2160, fps: 30, codec: .hevc, aspect: .sixteenNine, bitrate: 30_000_000),
        ExportPreset(label: "1080p 60fps", width: 1920, height: 1080, fps: 60, codec: .hevc, aspect: .sixteenNine, bitrate: 15_000_000),
        ExportPreset(label: "1080p 30fps", width: 1920, height: 1080, fps: 30, codec: .hevc, aspect: .sixteenNine, bitrate: 10_000_000),
        ExportPreset(label: "720p 30fps",  width: 1280, height: 720,  fps: 30, codec: .h264, aspect: .sixteenNine, bitrate: 6_000_000),
        ExportPreset(label: "Portrait 1080",     width: 1080, height: 1920, fps: 60, codec: .hevc, aspect: .nineSixteen, bitrate: 15_000_000),
        ExportPreset(label: "Square 1080",       width: 1080, height: 1080, fps: 60, codec: .hevc, aspect: .oneOne, bitrate: 12_000_000),
    ]
    static var defaultPreset: ExportPreset { presets[2] }
}
