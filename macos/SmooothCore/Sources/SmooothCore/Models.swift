import Foundation

// MARK: - Geometry primitives

public struct SizeD: Equatable, Sendable, Codable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct RectD: Equatable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct SizeI: Equatable, Sendable, Codable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) {
        self.width = width; self.height = height
    }
}

// MARK: - Enums (raw values match the original TypeScript string unions)

public enum AspectRatio: String, Codable, Sendable, CaseIterable {
    case r16x9 = "16:9"
    case r16x10 = "16:10"
    case r3x2 = "3:2"
    case r9x16 = "9:16"
    case r4x3 = "4:3"
    case r3x4 = "3:4"
    case r1x1 = "1:1"

    /// Width/height ratio components.
    public var components: (w: Double, h: Double) {
        let parts = rawValue.split(separator: ":").compactMap { Double($0) }
        return (parts[0], parts[1])
    }
}

public enum EventType: String, Codable, Sendable {
    case click, move, scroll
}

public enum ZoomMode: String, Codable, Sendable {
    case auto, fixed
}

public enum BackgroundType: String, Codable, Sendable {
    case color, gradient, image, wallpaper
}

public enum WebcamShape: String, Codable, Sendable {
    case circle, square, rectangle
}

public enum WebcamPos: String, Codable, Sendable, CaseIterable {
    case topLeft = "top-left"
    case topCenter = "top-center"
    case topRight = "top-right"
    case bottomLeft = "bottom-left"
    case bottomCenter = "bottom-center"
    case bottomRight = "bottom-right"
    case leftCenter = "left-center"
    case rightCenter = "right-center"
}

// MARK: - Recorded mouse metadata

public struct MetaDataItem: Codable, Equatable, Sendable {
    public var timestamp: Double
    public var x: Double
    public var y: Double
    public var type: EventType
    public var button: String?
    public var pressed: Bool?
    public var cursorImageKey: String?

    public init(timestamp: Double, x: Double, y: Double, type: EventType,
                button: String? = nil, pressed: Bool? = nil, cursorImageKey: String? = nil) {
        self.timestamp = timestamp; self.x = x; self.y = y; self.type = type
        self.button = button; self.pressed = pressed; self.cursorImageKey = cursorImageKey
    }
}

// MARK: - Timeline regions

public struct ZoomRegion: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var startTime: Double
    public var duration: Double
    public var zoomLevel: Double
    public var easing: String
    public var transitionDuration: Double
    public var targetX: Double
    public var targetY: Double
    public var mode: ZoomMode
    public var zIndex: Int

    public init(id: String, startTime: Double, duration: Double, zoomLevel: Double,
                easing: String, transitionDuration: Double, targetX: Double, targetY: Double,
                mode: ZoomMode, zIndex: Int = 0) {
        self.id = id; self.startTime = startTime; self.duration = duration
        self.zoomLevel = zoomLevel; self.easing = easing; self.transitionDuration = transitionDuration
        self.targetX = targetX; self.targetY = targetY; self.mode = mode; self.zIndex = zIndex
    }
}

public struct CutRegion: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var startTime: Double
    public var duration: Double
    public var trimType: String?
    public var zIndex: Int

    public init(id: String, startTime: Double, duration: Double, trimType: String? = nil, zIndex: Int = 0) {
        self.id = id; self.startTime = startTime; self.duration = duration
        self.trimType = trimType; self.zIndex = zIndex
    }
}

public struct SpeedRegion: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var startTime: Double
    public var duration: Double
    public var speed: Double
    public var zIndex: Int

    public init(id: String, startTime: Double, duration: Double, speed: Double, zIndex: Int = 0) {
        self.id = id; self.startTime = startTime; self.duration = duration
        self.speed = speed; self.zIndex = zIndex
    }
}

// MARK: - Style models

public struct Background: Codable, Equatable, Sendable {
    public var type: BackgroundType
    public var color: String?
    public var gradientStart: String?
    public var gradientEnd: String?
    public var gradientDirection: String?
    public var imageUrl: String?
    public var thumbnailUrl: String?

    public init(type: BackgroundType, color: String? = nil, gradientStart: String? = nil,
                gradientEnd: String? = nil, gradientDirection: String? = nil,
                imageUrl: String? = nil, thumbnailUrl: String? = nil) {
        self.type = type; self.color = color; self.gradientStart = gradientStart
        self.gradientEnd = gradientEnd; self.gradientDirection = gradientDirection
        self.imageUrl = imageUrl; self.thumbnailUrl = thumbnailUrl
    }
}

public struct FrameStyles: Codable, Equatable, Sendable {
    public var padding: Double
    public var background: Background
    public var borderRadius: Double
    public var shadowBlur: Double
    public var shadowOffsetX: Double
    public var shadowOffsetY: Double
    public var shadowColor: String
    public var borderWidth: Double
    public var borderColor: String

    public init(padding: Double, background: Background, borderRadius: Double, shadowBlur: Double,
                shadowOffsetX: Double, shadowOffsetY: Double, shadowColor: String,
                borderWidth: Double, borderColor: String) {
        self.padding = padding; self.background = background; self.borderRadius = borderRadius
        self.shadowBlur = shadowBlur; self.shadowOffsetX = shadowOffsetX; self.shadowOffsetY = shadowOffsetY
        self.shadowColor = shadowColor; self.borderWidth = borderWidth; self.borderColor = borderColor
    }
}

/// How the pointer is rendered. `.system` draws the real captured cursor bitmap;
/// the others are synthetic and work on any recording (even with no captured image).
public enum CursorTheme: String, Codable, Sendable, CaseIterable {
    case system = "System"
    case classic = "Classic"
    case dot = "Dot"
    case highlight = "Highlight"
}

public struct CursorStyles: Codable, Equatable, Sendable {
    public var showCursor: Bool
    public var shadowBlur: Double
    public var shadowOffsetX: Double
    public var shadowOffsetY: Double
    public var shadowColor: String
    public var clickRippleEffect: Bool
    public var clickRippleColor: String
    public var clickRippleSize: Double
    public var clickRippleDuration: Double
    public var clickScaleEffect: Bool
    public var clickScaleAmount: Double
    public var clickScaleDuration: Double
    public var clickScaleEasing: String
    public var theme: CursorTheme
    /// Render size for synthetic themes (points in recording space). Ignored by `.system`.
    public var size: Double

    public init(showCursor: Bool, shadowBlur: Double, shadowOffsetX: Double, shadowOffsetY: Double,
                shadowColor: String, clickRippleEffect: Bool, clickRippleColor: String,
                clickRippleSize: Double, clickRippleDuration: Double, clickScaleEffect: Bool,
                clickScaleAmount: Double, clickScaleDuration: Double, clickScaleEasing: String,
                theme: CursorTheme = .system, size: Double = 28) {
        self.showCursor = showCursor; self.shadowBlur = shadowBlur; self.shadowOffsetX = shadowOffsetX
        self.shadowOffsetY = shadowOffsetY; self.shadowColor = shadowColor
        self.clickRippleEffect = clickRippleEffect; self.clickRippleColor = clickRippleColor
        self.clickRippleSize = clickRippleSize; self.clickRippleDuration = clickRippleDuration
        self.clickScaleEffect = clickScaleEffect; self.clickScaleAmount = clickScaleAmount
        self.clickScaleDuration = clickScaleDuration; self.clickScaleEasing = clickScaleEasing
        self.theme = theme; self.size = size
    }

    // Tolerant decode: older recordings/presets have no `theme`/`size`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showCursor = try c.decode(Bool.self, forKey: .showCursor)
        shadowBlur = try c.decode(Double.self, forKey: .shadowBlur)
        shadowOffsetX = try c.decode(Double.self, forKey: .shadowOffsetX)
        shadowOffsetY = try c.decode(Double.self, forKey: .shadowOffsetY)
        shadowColor = try c.decode(String.self, forKey: .shadowColor)
        clickRippleEffect = try c.decode(Bool.self, forKey: .clickRippleEffect)
        clickRippleColor = try c.decode(String.self, forKey: .clickRippleColor)
        clickRippleSize = try c.decode(Double.self, forKey: .clickRippleSize)
        clickRippleDuration = try c.decode(Double.self, forKey: .clickRippleDuration)
        clickScaleEffect = try c.decode(Bool.self, forKey: .clickScaleEffect)
        clickScaleAmount = try c.decode(Double.self, forKey: .clickScaleAmount)
        clickScaleDuration = try c.decode(Double.self, forKey: .clickScaleDuration)
        clickScaleEasing = try c.decode(String.self, forKey: .clickScaleEasing)
        theme = try c.decodeIfPresent(CursorTheme.self, forKey: .theme) ?? .system
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 28
    }

    private enum CodingKeys: String, CodingKey {
        case showCursor, shadowBlur, shadowOffsetX, shadowOffsetY, shadowColor
        case clickRippleEffect, clickRippleColor, clickRippleSize, clickRippleDuration
        case clickScaleEffect, clickScaleAmount, clickScaleDuration, clickScaleEasing
        case theme, size
    }
}

public struct WebcamStyles: Codable, Equatable, Sendable {
    public var shape: WebcamShape
    public var borderRadius: Double
    public var size: Double
    public var shadowBlur: Double
    public var shadowOffsetX: Double
    public var shadowOffsetY: Double
    public var shadowColor: String
    public var isFlipped: Bool
    public var scaleOnZoom: Bool
    public var smartPosition: Bool

    public init(shape: WebcamShape, borderRadius: Double, size: Double, shadowBlur: Double,
                shadowOffsetX: Double, shadowOffsetY: Double, shadowColor: String,
                isFlipped: Bool, scaleOnZoom: Bool, smartPosition: Bool) {
        self.shape = shape; self.borderRadius = borderRadius; self.size = size
        self.shadowBlur = shadowBlur; self.shadowOffsetX = shadowOffsetX; self.shadowOffsetY = shadowOffsetY
        self.shadowColor = shadowColor; self.isFlipped = isFlipped
        self.scaleOnZoom = scaleOnZoom; self.smartPosition = smartPosition
    }
}

public struct Preset: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var styles: FrameStyles
    public var aspectRatio: AspectRatio
    public var isDefault: Bool?
    public var webcamStyles: WebcamStyles?
    public var webcamPosition: WebcamPos?
    public var isWebcamVisible: Bool?

    public init(id: String, name: String, styles: FrameStyles, aspectRatio: AspectRatio,
                isDefault: Bool? = nil, webcamStyles: WebcamStyles? = nil,
                webcamPosition: WebcamPos? = nil, isWebcamVisible: Bool? = nil) {
        self.id = id; self.name = name; self.styles = styles; self.aspectRatio = aspectRatio
        self.isDefault = isDefault; self.webcamStyles = webcamStyles
        self.webcamPosition = webcamPosition; self.isWebcamVisible = isWebcamVisible
    }
}
