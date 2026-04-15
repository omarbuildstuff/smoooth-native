import CoreGraphics
import CoreMedia
import Foundation

/// Cursor position sample. Recorded at ~120Hz + on every mouseMoved event.
struct CursorSample: Codable, Hashable {
    let time: CMTime       // session-relative
    let position: CGPoint  // in source display pixels
}
