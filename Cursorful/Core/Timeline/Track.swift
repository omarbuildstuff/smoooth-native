import Foundation

/// Marker type for future generality. Not used directly in MVP — we keep zoom + clip tracks as
/// named properties on `Project`.
enum TrackKind: String, Codable { case clip, zoom, audio }
