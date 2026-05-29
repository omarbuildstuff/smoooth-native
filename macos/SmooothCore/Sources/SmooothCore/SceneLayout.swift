import Foundation

/// The padded, aspect-fit frame placement inside an output of `outputWidth × outputHeight`.
/// Shared by the CGContext compositor (export) and the GPU layer preview so they never drift.
public struct SceneLayout: Equatable, Sendable {
    public var frameX: Double
    public var frameY: Double
    public var frameContentWidth: Double
    public var frameContentHeight: Double

    public static func compute(outputWidth: Double, outputHeight: Double,
                               videoDimensions: SizeD, padding: Double) -> SceneLayout {
        let paddingPercent = padding / 100
        let availableWidth = outputWidth * (1 - 2 * paddingPercent)
        let availableHeight = outputHeight * (1 - 2 * paddingPercent)
        let videoAspect = videoDimensions.width / videoDimensions.height

        var w: Double
        var h: Double
        if availableWidth / availableHeight > videoAspect {
            h = availableHeight
            w = (h * videoAspect).rounded()
            h = (w / videoAspect).rounded()
        } else {
            w = availableWidth
            h = (w / videoAspect).rounded()
            w = (h * videoAspect).rounded()
        }
        let x = ((outputWidth - w) / 2).rounded()
        let y = ((outputHeight - h) / 2).rounded()
        return SceneLayout(frameX: x, frameY: y, frameContentWidth: w, frameContentHeight: h)
    }
}
