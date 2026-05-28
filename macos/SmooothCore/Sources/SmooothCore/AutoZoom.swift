import Foundation

/// Auto-zoom generation from click metadata, ported from
/// `generateZoomRegionsFromClicks` (timelineSlice.ts) + `synthesizeClicksFromMoves`
/// (utils.ts). When no real click events exist, clicks are synthesized from
/// cursor-dwell patterns.
public enum AutoZoom {

    /// Synthesize click-like events from cursor pauses in move events.
    public static func synthesizeClicksFromMoves(_ metadata: [MetaDataItem]) -> [MetaDataItem] {
        let pauseRadius = 15.0
        let minPauseS = 0.1
        let maxPauseS = 2.5

        let moves = metadata.filter { $0.type == .move }.sorted { $0.timestamp < $1.timestamp }
        if moves.isEmpty { return [] }

        var synthetic: [MetaDataItem] = []
        var i = 0
        while i < moves.count {
            let anchor = moves[i]
            var j = i + 1
            while j < moves.count
                && abs(moves[j].x - anchor.x) <= pauseRadius
                && abs(moves[j].y - anchor.y) <= pauseRadius {
                j += 1
            }
            let dwellS = moves[min(j, moves.count) - 1].timestamp - anchor.timestamp
            if dwellS >= minPauseS && dwellS <= maxPauseS {
                var click = anchor
                click.type = .click
                click.pressed = true
                synthetic.append(click)
            }
            i = j
        }
        return synthetic
    }

    /// Generate zoom regions from click groups. Returns regions with `zIndex == 0`
    /// (callers re-stack by duration). IDs match the JS form `zoom-auto-<ms>`.
    public static func generate(metadata: [MetaDataItem], recordingGeometry: SizeD, duration: Double) -> [ZoomRegion] {
        if duration == 0 { return [] }

        var clicks = metadata.filter { $0.type == .click }.sorted { $0.timestamp < $1.timestamp }
        if clicks.isEmpty {
            clicks = synthesizeClicksFromMoves(metadata).sorted { $0.timestamp < $1.timestamp }
        }
        if clicks.isEmpty { return [] }

        let transitionDuration = Defaults.Zoom.speedOptions[Defaults.Zoom.defaultSpeed]!

        var groups: [(first: MetaDataItem, last: MetaDataItem)] = []
        var groupStart = clicks[0]
        var groupEnd = clicks[0]
        for i in 1..<clicks.count {
            if clicks[i].timestamp - groupEnd.timestamp < Defaults.Zoom.autoMinDuration {
                groupEnd = clicks[i]
            } else {
                groups.append((groupStart, groupEnd))
                groupStart = clicks[i]
                groupEnd = clicks[i]
            }
        }
        groups.append((groupStart, groupEnd))

        var regions: [ZoomRegion] = []
        for group in groups {
            let first = group.first
            let last = group.last
            let startTime = max(0, first.timestamp - Defaults.Zoom.autoPreClickOffset)
            let rawDuration = last.timestamp + Defaults.Zoom.autoPostClickPadding - startTime
            let regionDuration = max(Defaults.Zoom.autoMinDuration, min(rawDuration, duration - startTime))
            if regionDuration < Defaults.Timeline.minimumRegionDuration { continue }

            let id = "zoom-auto-\(Int((first.timestamp * 1000).rounded()))"
            regions.append(ZoomRegion(
                id: id,
                startTime: startTime,
                duration: regionDuration,
                zoomLevel: Defaults.Zoom.defaultLevel,
                easing: Defaults.Zoom.defaultEasing,
                transitionDuration: transitionDuration,
                targetX: first.x / recordingGeometry.width - 0.5,
                targetY: first.y / recordingGeometry.height - 0.5,
                mode: .auto,
                zIndex: 0
            ))
        }
        return regions
    }
}
