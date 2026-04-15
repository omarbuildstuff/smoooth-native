import CoreMedia
import Foundation

/// A trimmed segment of the source video. For MVP there's always one clip that covers the whole
/// recording; trim handles adjust `trimIn` / `trimOut`.
struct Clip: Codable, Hashable, Identifiable {
    var id: UUID
    var trimIn: CMTime    // offset from start of source
    var trimOut: CMTime   // inclusive end time (source-relative)

    var duration: CMTime { CMTimeSubtract(trimOut, trimIn) }
}
