import Foundation

/// Maps export-timeline time to source-video time accounting for cut and speed
/// regions. Ported from `mapExportTimeToSourceTime` in `src/lib/utils.ts`.
public enum TimeRemap {

    public static func mapExportTimeToSourceTime(_ exportTime: Double,
                                                 duration: Double,
                                                 cutRegions: [String: CutRegion],
                                                 speedRegions: [String: SpeedRegion]) -> Double {
        let allCuts = Array(cutRegions.values)
        let allSpeeds = Array(speedRegions.values)

        var events = Set<Double>([0, duration])
        for r in allCuts {
            events.insert(r.startTime)
            events.insert(r.startTime + r.duration)
        }
        for r in allSpeeds {
            events.insert(r.startTime)
            events.insert(r.startTime + r.duration)
        }
        let sortedEvents = events.sorted().filter { $0 >= 0 && $0 <= duration }

        var accumulatedExportTime = 0.0
        var sourceTime = 0.0

        guard sortedEvents.count >= 2 else { return sourceTime }
        for i in 0..<(sortedEvents.count - 1) {
            let segmentStart = sortedEvents[i]
            let segmentEnd = sortedEvents[i + 1]
            let segmentSourceDuration = segmentEnd - segmentStart
            let midpoint = segmentStart + segmentSourceDuration / 2

            let isCut = allCuts.contains { midpoint >= $0.startTime && midpoint < $0.startTime + $0.duration }
            if isCut {
                sourceTime = segmentEnd
                continue
            }

            let activeSpeed = allSpeeds.first { midpoint >= $0.startTime && midpoint < $0.startTime + $0.duration }
            let speed = activeSpeed?.speed ?? 1
            let segmentExportDuration = segmentSourceDuration / speed
            let endOfSegmentExportTime = accumulatedExportTime + segmentExportDuration

            if exportTime <= endOfSegmentExportTime {
                let timeIntoSegmentExport = exportTime - accumulatedExportTime
                let timeIntoSegmentSource = timeIntoSegmentExport * speed
                return segmentStart + timeIntoSegmentSource
            }

            accumulatedExportTime = endOfSegmentExportTime
            sourceTime = segmentEnd
        }

        return sourceTime
    }

    /// Final export duration after cuts (removed) and speed regions (compressed).
    /// Mirrors the duration math in `RendererPage`.
    public static func exportDuration(_ duration: Double,
                                      cutRegions: [String: CutRegion],
                                      speedRegions: [String: SpeedRegion]) -> Double {
        var d = duration
        for r in cutRegions.values { d -= r.duration }
        for r in speedRegions.values {
            d -= r.duration
            d += r.duration / r.speed
        }
        return max(0, d)
    }
}
