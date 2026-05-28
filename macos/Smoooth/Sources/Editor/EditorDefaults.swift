import Foundation
import CoreGraphics
import ImageIO
import SmooothCore

/// Factory for initial editor state, matching the original `frameSlice`/`webcamSlice`
/// defaults and the bundled wallpaper catalog.
enum EditorDefaults {
    static let defaultPresetID = "default-preset-v1"

    /// 17 bundled wallpapers (basename, no extension). The first is the default background.
    static let wallpapers: [String] = (1...17).map { String(format: "wallpaper-%04d", $0) }

    static func wallpaperImageURL(_ basename: String) -> String {
        "wallpapers/images/\(basename).jpg"
    }

    static func defaultBackground() -> Background {
        Background(type: .wallpaper,
                   imageUrl: wallpaperImageURL(wallpapers[0]),
                   thumbnailUrl: wallpaperImageURL(wallpapers[0]))
    }

    static func defaultFrameStyles() -> FrameStyles {
        FrameStyles(
            padding: Defaults.Frame.padding.defaultValue,
            background: defaultBackground(),
            borderRadius: Defaults.Frame.radius.defaultValue,
            shadowBlur: Defaults.Frame.shadowBlur.defaultValue,
            shadowOffsetX: Defaults.Frame.shadowOffsetX.defaultValue,
            shadowOffsetY: Defaults.Frame.shadowOffsetY.defaultValue,
            shadowColor: Defaults.Frame.shadowColorRGBA,
            borderWidth: Defaults.Frame.borderWidth.defaultValue,
            borderColor: Defaults.Frame.borderColorRGBA)
    }

    static func defaultCursorStyles() -> CursorStyles {
        CursorStyles(
            showCursor: Defaults.Cursor.showCursorDefault,
            shadowBlur: Defaults.Cursor.shadowBlur.defaultValue,
            shadowOffsetX: Defaults.Cursor.shadowOffsetX.defaultValue,
            shadowOffsetY: Defaults.Cursor.shadowOffsetY.defaultValue,
            shadowColor: Defaults.Cursor.shadowColorRGBA,
            clickRippleEffect: Defaults.Cursor.clickRippleEnabled,
            clickRippleColor: Defaults.Cursor.clickRippleColor,
            clickRippleSize: Defaults.Cursor.clickRippleSize.defaultValue,
            clickRippleDuration: Defaults.Cursor.clickRippleDuration.defaultValue,
            clickScaleEffect: Defaults.Cursor.clickScaleEnabled,
            clickScaleAmount: Defaults.Cursor.clickScaleAmount.defaultValue,
            clickScaleDuration: Defaults.Cursor.clickScaleDuration.defaultValue,
            clickScaleEasing: Defaults.Cursor.clickScaleEasing)
    }

    static func defaultWebcamStyles() -> WebcamStyles {
        WebcamStyles(
            shape: Defaults.Camera.shapeDefault,
            borderRadius: Defaults.Camera.radius.defaultValue,
            size: Defaults.Camera.size.defaultValue,
            shadowBlur: Defaults.Camera.blur.defaultValue,
            shadowOffsetX: Defaults.Camera.offsetX.defaultValue,
            shadowOffsetY: Defaults.Camera.offsetY.defaultValue,
            shadowColor: Defaults.Camera.shadowColorRGBA,
            isFlipped: Defaults.Camera.flipDefault,
            scaleOnZoom: Defaults.Camera.scaleOnZoomDefault,
            smartPosition: Defaults.Camera.smartPositionEnabled)
    }

    static func defaultPreset() -> Preset {
        Preset(id: defaultPresetID, name: "Default", styles: defaultFrameStyles(),
               aspectRatio: .r16x9, isDefault: true, webcamStyles: defaultWebcamStyles(),
               webcamPosition: Defaults.Camera.positionDefault, isWebcamVisible: false)
    }
}

/// Loads images (bundled wallpapers by relative url, or user files by path/URL) as CGImage.
enum ImageLoader {
    static func cgImage(forBackgroundURL urlString: String?) -> CGImage? {
        guard let urlString, !urlString.isEmpty else { return nil }
        // Bundled wallpaper: resolve by basename.
        if urlString.contains("wallpapers/") {
            let base = (urlString as NSString).lastPathComponent
            let name = (base as NSString).deletingPathExtension
            if let url = Bundle.main.url(forResource: name, withExtension: "jpg") {
                return load(url)
            }
            return nil
        }
        // File URL or path (user-imported image).
        let url = urlString.hasPrefix("file://") ? URL(string: urlString) : URL(fileURLWithPath: urlString)
        guard let url else { return nil }
        return load(url)
    }

    static func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
