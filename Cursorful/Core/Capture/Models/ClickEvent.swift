import CoreGraphics
import CoreMedia
import Foundation

/// A pointer click recorded during capture. Position is in the global CGDisplay coordinate system
/// (0,0 at the top-left of the primary display, matching AppKit's screen coordinates after flip).
struct ClickEvent: Codable, Hashable {
    enum Button: String, Codable { case left, right, middle, other }

    let time: CMTime         // session-relative
    let position: CGPoint    // in source display pixels
    let button: Button
    let modifiers: UInt      // CGEventFlags rawValue
    let isDown: Bool         // true for mouse down, false for up
}
