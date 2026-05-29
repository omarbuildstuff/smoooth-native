import Foundation
import CoreGraphics
import SmooothCore

/// Decodes the recording metadata JSON written by the capture engine (and the
/// original Electron app) into events + cursor bitmaps the renderer consumes.
struct RecordingMetadata: Decodable {
    // x/y are optional: `geometry` carries them, but `screenSize` is written as
    // width/height only — if x/y were required, decoding screenSize would throw and
    // the whole metadata load would fail (→ no events, no cursor, no auto-zoom).
    struct Geo: Decodable { let x: Double?; let y: Double?; let width: Double; let height: Double }
    struct CursorImageData: Decodable {
        let width: Int
        let height: Int
        let xhot: Double
        let yhot: Double
        let image: [Int]
    }
    let platform: String?
    let geometry: Geo?
    let screenSize: Geo?
    let syncOffset: Double?
    let cursorImages: [String: CursorImageData]?
    let events: [MetaDataItem]

    static func load(_ url: URL) throws -> RecordingMetadata {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(RecordingMetadata.self, from: data)
    }

    var recordingGeometry: RectD? {
        guard let g = geometry, g.width > 0, g.height > 0 else { return nil }
        return RectD(x: g.x ?? 0, y: g.y ?? 0, width: g.width, height: g.height)
    }

    /// Builds renderable cursor bitmaps keyed by `cursorImageKey`.
    func cursorBitmaps() -> [String: CursorBitmap] {
        var out: [String: CursorBitmap] = [:]
        guard let images = cursorImages else { return out }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        for (key, c) in images {
            guard c.width > 0, c.height > 0, c.image.count == c.width * c.height * 4 else { continue }
            let bytes = c.image.map { UInt8(clamping: $0) }
            guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { continue }
            // Capture writes premultiplied RGBA in big-endian byte order (R,G,B,A
            // memory bytes); decode with the matching flags to avoid edge halos /
            // channel swaps.
            let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            guard let cg = CGImage(width: c.width, height: c.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                   bytesPerRow: c.width * 4, space: srgb,
                                   bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                                   provider: provider, decode: nil, shouldInterpolate: true,
                                   intent: .defaultIntent) else { continue }
            out[key] = CursorBitmap(image: cg, width: Double(c.width), height: Double(c.height),
                                    xhot: c.xhot, yhot: c.yhot)
        }
        return out
    }
}
