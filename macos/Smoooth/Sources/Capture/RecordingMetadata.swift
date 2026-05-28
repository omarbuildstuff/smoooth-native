import Foundation
import SmooothCore

/// The metadata JSON written next to every recording, in the exact shape the
/// editor loads (src/types/index.ts + recording-manager.ts
/// `processAndSaveMetadata`):
///
/// ```json
/// { "platform": "darwin",
///   "screenSize": { "width": W, "height": H },
///   "geometry": { "x": X, "y": Y, "width": W, "height": H },
///   "syncOffset": 0,
///   "cursorImages": { "<key>": { "width":.., "height":.., "xhot":.., "yhot":.., "image":[bytes...] } },
///   "events": [ { "timestamp":sec, "x":.., "y":.., "type":"move|click|scroll", "pressed":bool, "cursorImageKey":"<key>" } ] }
/// ```
///
/// The `events` array decodes cleanly into `[SmooothCore.MetaDataItem]` and the
/// whole document round-trips through `JSONDecoder`.
struct RecordingMetadata: Codable {
    var platform: String
    var screenSize: SizeI
    var geometry: RecordingGeometry
    var syncOffset: Double
    var cursorImages: [String: CursorImagePayload]
    var events: [MetaDataItem]

    struct CursorImagePayload: Codable {
        var width: Int
        var height: Int
        var xhot: Int
        var yhot: Int
        var image: [UInt8]
    }
}

extension RecordingMetadata {
    /// Builds the document from captured samples + cursor images.
    ///
    /// - `samples`: raw global samples (absolute seconds, physical-pixel coords).
    /// - `cursors`: distinct cursor images keyed by `cursorImageKey`.
    /// - `geometry`: the physical-pixel recording rect.
    /// - `screenSize`: primary-display size (the original wrote
    ///   `primaryDisplay.size`).
    /// - `videoStartWallClock`: wall-clock seconds of the first video frame; used
    ///   to rebase event timestamps so the first frame ≈ t=0.
    ///
    /// Events are filtered to the geometry bounds and made **relative** to the
    /// geometry origin — the precise behavior of the Electron `on('data')`
    /// handler in recording-manager.ts.
    static func build(samples: [RawMouseSample],
                      cursors: [String: CapturedCursorImage],
                      geometry: RecordingGeometry,
                      screenSize: SizeI,
                      videoStartWallClock: Double?) -> RecordingMetadata {
        let originX = Double(geometry.x)
        let originY = Double(geometry.y)
        let maxX = originX + Double(geometry.width)
        let maxY = originY + Double(geometry.height)
        let startTime = videoStartWallClock

        var events: [MetaDataItem] = []
        events.reserveCapacity(samples.count)

        for sample in samples {
            // Geometry filter (inclusive, matching the original bounds check).
            guard sample.x >= originX, sample.x <= maxX,
                  sample.y >= originY, sample.y <= maxY else {
                continue
            }

            // Relative coordinates.
            let relX = sample.x - originX
            let relY = sample.y - originY

            // Timestamp in seconds, rebased so the first frame is ~0 and never
            // negative (matches `Math.max(0, event.timestamp - videoStartTime)`).
            let seconds: Double
            if let startTime {
                seconds = max(0, sample.timestamp - startTime)
            } else {
                seconds = max(0, sample.timestamp)
            }

            events.append(MetaDataItem(
                timestamp: seconds,
                x: relX,
                y: relY,
                type: sample.kind.eventType,
                button: sample.button,
                pressed: sample.pressed,
                cursorImageKey: sample.cursorImageKey
            ))
        }

        let cursorPayloads = cursors.mapValues { cursor in
            CursorImagePayload(
                width: cursor.width,
                height: cursor.height,
                xhot: cursor.xhot,
                yhot: cursor.yhot,
                image: cursor.image
            )
        }

        return RecordingMetadata(
            platform: "darwin",
            screenSize: screenSize,
            geometry: geometry,
            syncOffset: 0,
            cursorImages: cursorPayloads,
            events: events
        )
    }

    /// Serializes and writes the document to `url`.
    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        // Compact, like the original `JSON.stringify(finalMetadata)`.
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}

private extension RawMouseSample.Kind {
    var eventType: EventType {
        switch self {
        case .move: return .move
        case .click: return .click
        case .scroll: return .scroll
        }
    }
}
