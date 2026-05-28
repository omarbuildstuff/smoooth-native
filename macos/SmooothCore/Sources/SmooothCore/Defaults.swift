import Foundation

/// All numeric defaults / ranges ported from `src/lib/constants.ts`. Values are
/// exact so a fresh project matches the original app pixel-for-pixel.
public enum Defaults {
    public struct Range: Sendable {
        public let min: Double
        public let max: Double
        public let step: Double
        public let defaultValue: Double
        public init(_ min: Double, _ max: Double, _ step: Double, _ def: Double) {
            self.min = min; self.max = max; self.step = step; self.defaultValue = def
        }
    }

    public enum Frame {
        public static let padding = Range(0, 30, 1, 5)
        public static let radius = Range(0, 100, 1, 16)
        public static let shadowBlur = Range(0, 100, 1, 35)
        public static let shadowOffsetX = Range(-50, 50, 1, 0)
        public static let shadowOffsetY = Range(-50, 50, 1, 15)
        public static let shadowOpacity = Range(0, 1, 0.01, 0.8)
        public static let shadowColorRGBA = "rgba(0, 0, 0, 0.8)"
        public static let borderWidth = Range(0, 20, 1, 4)
        public static let borderColorRGBA = "rgba(255, 255, 255, 0.2)"
    }

    public enum Camera {
        public static let shapeDefault: WebcamShape = .square
        public static let radius = Range(0, 50, 1, 35)
        public static let flipDefault = false
        public static let scaleOnZoomDefault = true
        public static let size = Range(10, 50, 1, 40)
        public static let positionDefault: WebcamPos = .bottomRight
        public static let blur = Range(0, 80, 1, 20)
        public static let offsetX = Range(-40, 40, 1, 0)
        public static let offsetY = Range(-40, 40, 1, 10)
        public static let opacity = Range(0, 1, 0.01, 0.4)
        public static let shadowColorRGBA = "rgba(0, 0, 0, 0.4)"
        public static let smartPositionEnabled = true
        public static let smartPositionLookahead = 0.1
        public static let smartPositionTransition = 0.5
        public static let smartPositionEasing = "Balanced"
        public static let scaleOnZoomAmount = 0.8
    }

    public enum Audio {
        public static let volume = Range(0, 1, 0.01, 1)
        public static let mutedDefault = false
    }

    public enum Cursor {
        public static let themeDefault = "Default"
        public static let scaleDefault = 2
        public static let showCursorDefault = true
        public static let shadowBlur = Range(0, 20, 1, 6)
        public static let shadowOffsetX = Range(-20, 20, 1, 3)
        public static let shadowOffsetY = Range(-20, 20, 1, 3)
        public static let shadowOpacity = Range(0, 1, 0.01, 0.4)
        public static let shadowColorRGBA = "rgba(0, 0, 0, 0.4)"
        public static let clickRippleEnabled = false
        public static let clickRippleSize = Range(10, 80, 1, 30)
        public static let clickRippleDuration = Range(0.1, 2.0, 0.05, 0.5)
        public static let clickRippleColor = "rgba(255, 255, 255, 0.8)"
        public static let clickScaleEnabled = true
        public static let clickScaleAmount = Range(0.5, 1.5, 0.05, 0.8)
        public static let clickScaleDuration = Range(0.1, 1, 0.05, 0.4)
        public static let clickScaleEasing = "Balanced"
    }

    public enum Zoom {
        public static let defaultSpeed = "Mellow"
        public static let speedOptions: [String: Double] = ["Slow": 1.5, "Mellow": 1.0, "Quick": 0.7, "Rapid": 0.4]
        public static let defaultLevel = 1.5
        public static let defaultDuration = 3.0
        public static let defaultEasing = "Balanced"
        public static let autoPreClickOffset = 1.0
        public static let autoPostClickPadding = 0.9
        public static let autoMinDuration = 3.0
        public static let panEasing = "Balanced"
        public static let level = Range(1, 3, 0.1, 1.5)
        /// transitionDuration implied by the default speed.
        public static var defaultTransitionDuration: Double { speedOptions[defaultSpeed]! }
    }

    public enum Timeline {
        public static let minimumRegionDuration = 0.1
        public static let regionDeleteThreshold = 0.05
    }

    public enum Resolutions {
        public static let p720 = SizeI(width: 1280, height: 720)
        public static let p1080 = SizeI(width: 1920, height: 1080)
        public static let k2 = SizeI(width: 2560, height: 1440)
        public static func height(_ key: String) -> Int {
            switch key {
            case "720p": return p720.height
            case "1080p": return p1080.height
            case "2k": return k2.height
            default: return p1080.height
            }
        }
    }

    public static let lastPresetIdKey = "smoooth_lastActivePresetId"
}
