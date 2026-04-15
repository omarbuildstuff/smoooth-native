import CoreGraphics
import CoreMedia
import Foundation

/// Non-destructive edit state persisted in `project.json` inside a `.cursorful` bundle.
struct Project: Codable, Hashable {
    var id: UUID
    var sourceVideoRelativePath: String      // "video.mov"
    var sourceSize: CGSize
    var sourceDuration: CMTime
    var clips: [Clip]
    var zoomTrack: [ZoomRegion]
    var cursor: CursorSettings
    var mockup: MockupSettings
    var background: BackgroundSettings
    var audio: AudioSettings
    var webcam: WebcamSettings?
    var export: ExportSettings

    static func newProject(for package: RecordingPackage,
                           meta: RecordingSessionMeta) -> Project {
        let size = CGSize(width: meta.sourceWidth, height: meta.sourceHeight)
        return Project(
            id: package.id,
            sourceVideoRelativePath: "video.mov",
            sourceSize: size,
            sourceDuration: meta.duration,
            clips: [Clip(id: UUID(), trimIn: .zero, trimOut: meta.duration)],
            zoomTrack: [],
            cursor: .default,
            mockup: .default,
            background: .default,
            audio: .default,
            webcam: nil,
            export: .default
        )
    }

    // MARK: - Persistence

    static func load(from package: RecordingPackage) -> Project? {
        guard let data = try? Data(contentsOf: package.projectURL) else { return nil }
        return try? JSONDecoder().decode(Project.self, from: data)
    }

    func save(to package: RecordingPackage) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: package.projectURL, options: .atomic)
    }
}

// MARK: - Sub-settings

struct CursorSettings: Codable, Hashable {
    var enabled: Bool
    var size: CGFloat
    var smoothing: CGFloat
    var showRipples: Bool

    static let `default` = CursorSettings(enabled: true, size: 0.022, smoothing: 0.35, showRipples: true)
}

struct MockupSettings: Codable, Hashable {
    var enabled: Bool
    var paddingRatio: CGFloat
    var cornerRadius: CGFloat
    var shadowStrength: CGFloat
    var shadowSpread: CGFloat

    static let `default` = MockupSettings(
        enabled: true, paddingRatio: 0.06, cornerRadius: 0.02,
        shadowStrength: 0.6, shadowSpread: 0.06
    )
}

struct BackgroundSettings: Codable, Hashable {
    enum Kind: String, Codable { case gradient, solid, image }
    var kind: Kind
    var topR: Double; var topG: Double; var topB: Double
    var botR: Double; var botG: Double; var botB: Double
    var imageRelativePath: String?

    static let `default` = BackgroundSettings(
        kind: .gradient,
        topR: 0.09, topG: 0.07, topB: 0.14,
        botR: 0.02, botG: 0.02, botB: 0.05,
        imageRelativePath: nil
    )
}

struct AudioSettings: Codable, Hashable {
    var systemVolume: Double
    var micVolume: Double
    var normalize: Bool
    static let `default` = AudioSettings(systemVolume: 1.0, micVolume: 1.0, normalize: true)
}

struct WebcamSettings: Codable, Hashable {
    enum Corner: String, Codable { case topLeft, topRight, bottomLeft, bottomRight }
    var corner: Corner
    var sizeFraction: Double
    var shape: String       // "circle" | "rounded"
    var relativePath: String
}

struct ExportSettings: Codable, Hashable {
    enum AspectRatio: String, Codable { case sixteenNine = "16:9", nineSixteen = "9:16", oneOne = "1:1", fourThree = "4:3" }
    enum Resolution: String, Codable { case k4, k1080, k720 }
    enum Codec: String, Codable { case hevc, h264 }
    var aspect: AspectRatio
    var resolution: Resolution
    var fps: Int32
    var codec: Codec
    var bitrate: Int?
    static let `default` = ExportSettings(aspect: .sixteenNine, resolution: .k1080, fps: 60, codec: .hevc, bitrate: nil)
}

// CGSize / CGPoint are already Codable in recent SDKs — no retroactive conformance needed.
