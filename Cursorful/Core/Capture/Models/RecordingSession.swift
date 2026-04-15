import CoreGraphics
import CoreMedia
import Foundation

/// Metadata about a recording session, persisted to `meta.json` in the package bundle.
struct RecordingSessionMeta: Codable {
    let id: UUID
    let startedAt: Date
    let displayID: CGDirectDisplayID
    let sourceWidth: Int
    let sourceHeight: Int
    let pixelScale: Double           // backing scale (1 on Intel, 2 on Retina)
    let fps: Int32
    let codec: String                // "hevc" | "h264"
    var clockSessionStartSeconds: Double  // mutated when first-frame anchor lands
    var duration: CMTime                  // updated at stop
    var appVersion: String

    enum CodingKeys: String, CodingKey {
        case id, startedAt, displayID, sourceWidth, sourceHeight, pixelScale, fps, codec,
             clockSessionStartSeconds, duration, appVersion
    }
}
