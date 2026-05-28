import Foundation

/// Geometry, ruler, export-dimension and color helpers ported from
/// `renderer.ts`, `utils.ts`, and `RendererPage.tsx`.
public enum Geometry {

    /// Webcam frame rect for a position. Mirrors `getWebcamRectForPosition`.
    public static func webcamRect(for pos: WebcamPos, width: Double, height: Double,
                                  outputWidth: Double, outputHeight: Double) -> RectD {
        let baseSize = min(outputWidth, outputHeight)
        let edgePadding = baseSize * 0.02
        switch pos {
        case .topLeft:
            return RectD(x: edgePadding, y: edgePadding, width: width, height: height)
        case .topCenter:
            return RectD(x: (outputWidth - width) / 2, y: edgePadding, width: width, height: height)
        case .topRight:
            return RectD(x: outputWidth - width - edgePadding, y: edgePadding, width: width, height: height)
        case .leftCenter:
            return RectD(x: edgePadding, y: (outputHeight - height) / 2, width: width, height: height)
        case .rightCenter:
            return RectD(x: outputWidth - width - edgePadding, y: (outputHeight - height) / 2, width: width, height: height)
        case .bottomLeft:
            return RectD(x: edgePadding, y: outputHeight - height - edgePadding, width: width, height: height)
        case .bottomCenter:
            return RectD(x: (outputWidth - width) / 2, y: outputHeight - height - edgePadding, width: width, height: height)
        case .bottomRight:
            return RectD(x: outputWidth - width - edgePadding, y: outputHeight - height - edgePadding, width: width, height: height)
        }
    }

    /// Clockwise neighbour pair for smart-position, mirroring `ADJACENT_POSITIONS`.
    public static func adjacentPositions(_ pos: WebcamPos) -> (WebcamPos, WebcamPos) {
        switch pos {
        case .topLeft: return (.topCenter, .leftCenter)
        case .topCenter: return (.topLeft, .topRight)
        case .topRight: return (.topCenter, .rightCenter)
        case .rightCenter: return (.topRight, .bottomRight)
        case .bottomRight: return (.rightCenter, .bottomCenter)
        case .bottomCenter: return (.bottomRight, .bottomLeft)
        case .bottomLeft: return (.bottomCenter, .leftCenter)
        case .leftCenter: return (.bottomLeft, .topLeft)
        }
    }

    /// Ruler major/minor intervals for a zoom level. Mirrors `calculateRulerInterval`.
    public static func rulerInterval(pixelsPerSecond: Double) -> (major: Double, minor: Double) {
        let niceIntervals: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        let minMajorPixelSpacing = 90.0
        let major = niceIntervals.first { $0 * pixelsPerSecond > minMajorPixelSpacing } ?? niceIntervals.last!
        let minMinorPixelSpacing = 10.0
        for sub in [10.0, 5.0, 4.0, 2.0] {
            let minor = major / sub
            if minor * pixelsPerSecond > minMinorPixelSpacing {
                return (major, minor)
            }
        }
        return (major, major / 2)
    }

    /// Output pixel dimensions for a resolution + aspect ratio. Height-driven; width
    /// rounded then bumped to even. Mirrors the math in `RendererPage`.
    public static func exportDimensions(resolution: String, aspectRatio: AspectRatio) -> SizeI {
        let comps = aspectRatio.components
        let baseHeight = Defaults.Resolutions.height(resolution)
        var outputWidth = Int((Double(baseHeight) * (comps.w / comps.h)).rounded())
        if outputWidth % 2 != 0 { outputWidth += 1 }
        return SizeI(width: outputWidth, height: baseHeight)
    }

    /// Parses an `rgb()/rgba()` string to components. Mirrors `rgbaToHexAlpha` (returns
    /// raw 0–255 channels + 0–1 alpha; hex is derivable).
    public static func rgbaComponents(_ string: String) -> (r: Int, g: Int, b: Int, a: Double)? {
        let pattern = #"^rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?\)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(string.startIndex..., in: string)
        guard let m = regex.firstMatch(in: string, range: range) else { return nil }
        func intAt(_ i: Int) -> Int {
            guard let r = Range(m.range(at: i), in: string) else { return 0 }
            return Int(string[r]) ?? 0
        }
        let r = intAt(1), g = intAt(2), b = intAt(3)
        var a = 1.0
        if let aRange = Range(m.range(at: 4), in: string) {
            a = Double(string[aRange]) ?? 1.0
        }
        return (r, g, b, a)
    }

    /// Hex string `#rrggbb` for parsed components.
    public static func hex(_ r: Int, _ g: Int, _ b: Int) -> String {
        String(format: "#%02x%02x%02x", r, g, b)
    }
}
