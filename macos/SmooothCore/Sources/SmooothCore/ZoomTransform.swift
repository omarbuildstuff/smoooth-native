import Foundation

public struct ZoomTransformResult: Equatable, Sendable {
    public var scale: Double
    public var translateX: Double
    public var translateY: Double
    /// transform-origin as 0...1 fractions (the renderer multiplies by content size).
    public var originX: Double
    public var originY: Double

    public init(scale: Double, translateX: Double, translateY: Double, originX: Double, originY: Double) {
        self.scale = scale; self.translateX = translateX; self.translateY = translateY
        self.originX = originX; self.originY = originY
    }

    public static let identity = ZoomTransformResult(scale: 1, translateX: 0, translateY: 0, originX: 0.5, originY: 0.5)
}

/// Cinematic zoom/pan, ported from `src/lib/transform.ts`.
public enum ZoomTransform {

    static func lerp(_ start: Double, _ end: Double, _ t: Double) -> Double {
        start * (1 - t) + end * t
    }

    /// Index of the last metadata item with timestamp <= currentTime (binary search). -1 if none.
    public static func findLastMetadataIndex(_ metadata: [MetaDataItem], _ currentTime: Double) -> Int {
        if metadata.isEmpty { return -1 }
        var left = 0
        var right = metadata.count - 1
        var result = -1
        while left <= right {
            let mid = (left + right) / 2
            if metadata[mid].timestamp <= currentTime {
                result = mid
                left = mid + 1
            } else {
                right = mid - 1
            }
        }
        return result
    }

    static func smoothedMousePosition(_ metadata: [MetaDataItem], _ targetTime: Double,
                                      smoothingFactor: Double = 0.1) -> (x: Double, y: Double)? {
        let endIndex = findLastMetadataIndex(metadata, targetTime)
        if endIndex < 0 { return nil }
        let startTime = max(0, targetTime - 0.5)
        var startIndex = findLastMetadataIndex(metadata, startTime)
        if startIndex < 0 { startIndex = 0 }
        if startIndex >= metadata.count { return nil }

        var smoothedX = metadata[startIndex].x
        var smoothedY = metadata[startIndex].y
        if endIndex >= startIndex + 1 {
            for i in (startIndex + 1)...endIndex {
                smoothedX = lerp(smoothedX, metadata[i].x, smoothingFactor)
                smoothedY = lerp(smoothedY, metadata[i].y, smoothingFactor)
            }
        }

        let lastEvent = metadata[endIndex]
        if endIndex + 1 < metadata.count {
            let nextEvent = metadata[endIndex + 1]
            let timeDiff = nextEvent.timestamp - lastEvent.timestamp
            if timeDiff > 0 {
                let progress = (targetTime - lastEvent.timestamp) / timeDiff
                let finalX = lerp(smoothedX, nextEvent.x, smoothingFactor)
                let finalY = lerp(smoothedY, nextEvent.y, smoothingFactor)
                return (lerp(smoothedX, finalX, progress), lerp(smoothedY, finalY, progress))
            }
        }
        return (smoothedX, smoothedY)
    }

    static func boundedPan(_ mousePos: (x: Double, y: Double)?, origin: (x: Double, y: Double),
                           zoomLevel: Double, recordingGeometry: SizeD,
                           frameContent: SizeD) -> (tx: Double, ty: Double) {
        guard let mousePos else { return (0, 0) }
        let nsmx = mousePos.x / recordingGeometry.width
        let nsmy = mousePos.y / recordingGeometry.height
        let targetFinalPanX = (0.5 - ((nsmx - origin.x) * zoomLevel + origin.x)) * frameContent.width
        let targetFinalPanY = (0.5 - ((nsmy - origin.y) * zoomLevel + origin.y)) * frameContent.height
        let targetTranslateX = targetFinalPanX / zoomLevel
        let targetTranslateY = targetFinalPanY / zoomLevel
        let maxTx = (origin.x * frameContent.width * (zoomLevel - 1)) / zoomLevel
        let minTx = -((1 - origin.x) * frameContent.width * (zoomLevel - 1)) / zoomLevel
        let maxTy = (origin.y * frameContent.height * (zoomLevel - 1)) / zoomLevel
        let minTy = -((1 - origin.y) * frameContent.height * (zoomLevel - 1)) / zoomLevel
        let tx = max(minTx, min(maxTx, targetTranslateX))
        let ty = max(minTy, min(maxTy, targetTranslateY))
        return (tx, ty)
    }

    /// Calculates the zoom/pan transform at `currentTime`. Non-overlapping regions are
    /// selected by ascending startTime (the original relied on insertion order; in practice
    /// zoom regions never overlap).
    public static func calculate(currentTime: Double,
                                 zoomRegions: [String: ZoomRegion],
                                 metadata: [MetaDataItem],
                                 recordingGeometry: SizeD,
                                 frameContent: SizeD) -> ZoomTransformResult {
        let active = zoomRegions.values
            .sorted { $0.startTime < $1.startTime }
            .first { currentTime >= $0.startTime && currentTime < $0.startTime + $0.duration }
        guard let region = active else { return .identity }

        let startTime = region.startTime
        let duration = region.duration
        let zoomLevel = region.zoomLevel
        let transitionDuration = region.transitionDuration
        let zoomOutStartTime = startTime + duration - transitionDuration
        let zoomInEndTime = startTime + transitionDuration

        let origin = (x: region.targetX + 0.5, y: region.targetY + 0.5)

        var currentScale = 1.0
        var currentTranslateX = 0.0
        var currentTranslateY = 0.0

        var initialPan = (tx: 0.0, ty: 0.0)
        var livePan = (tx: 0.0, ty: 0.0)
        var finalPan = (tx: 0.0, ty: 0.0)

        if region.mode == .auto && !metadata.isEmpty && recordingGeometry.width > 0 {
            initialPan = boundedPan(smoothedMousePosition(metadata, zoomInEndTime), origin: origin,
                                    zoomLevel: zoomLevel, recordingGeometry: recordingGeometry, frameContent: frameContent)
            livePan = boundedPan(smoothedMousePosition(metadata, currentTime), origin: origin,
                                 zoomLevel: zoomLevel, recordingGeometry: recordingGeometry, frameContent: frameContent)
            finalPan = boundedPan(smoothedMousePosition(metadata, zoomOutStartTime), origin: origin,
                                  zoomLevel: zoomLevel, recordingGeometry: recordingGeometry, frameContent: frameContent)
        }

        let easing = Easing.curve(region.easing)

        if currentTime >= startTime && currentTime < zoomInEndTime {
            let t = easing((currentTime - startTime) / transitionDuration)
            currentScale = lerp(1, zoomLevel, t)
            currentTranslateX = lerp(0, initialPan.tx, t)
            currentTranslateY = lerp(0, initialPan.ty, t)
        } else if currentTime >= zoomInEndTime && currentTime < zoomOutStartTime {
            currentScale = zoomLevel
            currentTranslateX = livePan.tx
            currentTranslateY = livePan.ty
        } else if currentTime >= zoomOutStartTime && currentTime <= startTime + duration {
            let t = easing((currentTime - zoomOutStartTime) / transitionDuration)
            currentScale = lerp(zoomLevel, 1, t)
            currentTranslateX = lerp(finalPan.tx, 0, t)
            currentTranslateY = lerp(finalPan.ty, 0, t)
        }

        return ZoomTransformResult(scale: currentScale, translateX: currentTranslateX,
                                   translateY: currentTranslateY, originX: origin.x, originY: origin.y)
    }
}
