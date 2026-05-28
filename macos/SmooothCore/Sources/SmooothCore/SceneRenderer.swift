import CoreGraphics
import Foundation

/// A decoded cursor image with its hotspot, keyed in the scene by `cursorImageKey`.
public struct CursorBitmap: Sendable {
    public var image: CGImage
    public var width: Double
    public var height: Double
    public var xhot: Double
    public var yhot: Double
    public init(image: CGImage, width: Double, height: Double, xhot: Double, yhot: Double) {
        self.image = image; self.width = width; self.height = height
        self.xhot = xhot; self.yhot = yhot
    }
}

/// The styling + timeline subset needed to composite a frame (mirrors `RenderableState`).
public struct SceneModel: Sendable {
    public var frameStyles: FrameStyles
    public var videoDimensions: SizeD
    public var recordingGeometry: SizeD?
    public var zoomRegions: [String: ZoomRegion]
    public var metadata: [MetaDataItem]
    public var cursorStyles: CursorStyles
    public var isWebcamVisible: Bool
    public var webcamPosition: WebcamPos
    public var webcamStyles: WebcamStyles

    public init(frameStyles: FrameStyles, videoDimensions: SizeD, recordingGeometry: SizeD?,
                zoomRegions: [String: ZoomRegion], metadata: [MetaDataItem], cursorStyles: CursorStyles,
                isWebcamVisible: Bool, webcamPosition: WebcamPos, webcamStyles: WebcamStyles) {
        self.frameStyles = frameStyles; self.videoDimensions = videoDimensions
        self.recordingGeometry = recordingGeometry; self.zoomRegions = zoomRegions
        self.metadata = metadata; self.cursorStyles = cursorStyles
        self.isWebcamVisible = isWebcamVisible; self.webcamPosition = webcamPosition
        self.webcamStyles = webcamStyles
    }
}

/// The per-frame image inputs.
public struct SceneFrameInputs {
    public var mainVideo: CGImage
    public var webcamVideo: CGImage?
    public var backgroundImage: CGImage?
    public var cursorBitmaps: [String: CursorBitmap]
    public init(mainVideo: CGImage, webcamVideo: CGImage? = nil, backgroundImage: CGImage? = nil,
                cursorBitmaps: [String: CursorBitmap] = [:]) {
        self.mainVideo = mainVideo; self.webcamVideo = webcamVideo
        self.backgroundImage = backgroundImage; self.cursorBitmaps = cursorBitmaps
    }
}

/// Composites one output frame. CoreGraphics port of `src/lib/renderer.ts drawScene`.
/// Renders into a top-left coordinate space (origin top-left, +y downward) so the
/// arithmetic matches the original Canvas2D code 1:1.
public enum SceneRenderer {

    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a * (1 - t) + b * t }

    /// Convenience: allocate an opaque sRGB bitmap, render, and return a CGImage.
    public static func renderImage(model: SceneModel, inputs: SceneFrameInputs,
                                   currentTime: Double, outputSize: SizeI) -> CGImage? {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: outputSize.width, height: outputSize.height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        render(into: ctx, model: model, inputs: inputs, currentTime: currentTime,
               outputWidth: Double(outputSize.width), outputHeight: Double(outputSize.height))
        return ctx.makeImage()
    }

    /// Draws into an existing context. Sets up (and restores) a top-left flip.
    public static func render(into ctx: CGContext, model: SceneModel, inputs: SceneFrameInputs,
                              currentTime: Double, outputWidth: Double, outputHeight: Double) {
        guard model.videoDimensions.width > 0, model.videoDimensions.height > 0 else { return }
        ctx.saveGState()
        // Flip to a top-left origin coordinate system.
        ctx.translateBy(x: 0, y: outputHeight)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high

        drawBackground(ctx, width: outputWidth, height: outputHeight,
                       background: model.frameStyles.background, image: inputs.backgroundImage)

        // 2. Frame & content dimensions
        let fs = model.frameStyles
        let paddingPercent = fs.padding / 100
        let availableWidth = outputWidth * (1 - 2 * paddingPercent)
        let availableHeight = outputHeight * (1 - 2 * paddingPercent)
        let videoAspect = model.videoDimensions.width / model.videoDimensions.height

        var frameContentWidth: Double
        var frameContentHeight: Double
        if availableWidth / availableHeight > videoAspect {
            frameContentHeight = availableHeight
            frameContentWidth = (frameContentHeight * videoAspect).rounded()
            frameContentHeight = (frameContentWidth / videoAspect).rounded()
        } else {
            frameContentWidth = availableWidth
            frameContentHeight = (frameContentWidth / videoAspect).rounded()
            frameContentWidth = (frameContentHeight * videoAspect).rounded()
        }
        let frameX = ((outputWidth - frameContentWidth) / 2).rounded()
        let frameY = ((outputHeight - frameContentHeight) / 2).rounded()

        // 3. Zoom transform
        let recGeo = model.recordingGeometry ?? model.videoDimensions
        let zt = ZoomTransform.calculate(currentTime: currentTime, zoomRegions: model.zoomRegions,
                                         metadata: model.metadata, recordingGeometry: recGeo,
                                         frameContent: SizeD(width: frameContentWidth, height: frameContentHeight))
        let originPxX = zt.originX * frameContentWidth
        let originPxY = zt.originY * frameContentHeight

        ctx.saveGState()
        ctx.translateBy(x: frameX, y: frameY)
        ctx.translateBy(x: originPxX, y: originPxY)
        ctx.scaleBy(x: zt.scale, y: zt.scale)
        ctx.translateBy(x: zt.translateX, y: zt.translateY)
        ctx.translateBy(x: -originPxX, y: -originPxY)

        let contentRect = CGRect(x: 0, y: 0, width: frameContentWidth, height: frameContentHeight)
        let radius = min(fs.borderRadius, min(frameContentWidth, frameContentHeight) / 2)
        let roundedPath = CGPath(roundedRect: contentRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        // Shadow (drawn by filling the rounded path with shadow enabled)
        if fs.shadowBlur > 0 {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: fs.shadowOffsetX, height: -fs.shadowOffsetY),
                          blur: fs.shadowBlur, color: ColorParse.cgColor(fs.shadowColor))
            ctx.addPath(roundedPath)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fillPath()
            ctx.restoreGState()
        }

        // Video + border (clipped to rounded rect)
        ctx.saveGState()
        ctx.addPath(roundedPath)
        ctx.clip()
        drawImageTopLeft(ctx, inputs.mainVideo, in: contentRect)
        if fs.borderWidth > 0 {
            ctx.addPath(roundedPath)
            ctx.setStrokeColor(ColorParse.cgColor(fs.borderColor))
            ctx.setLineWidth(fs.borderWidth * 2)
            ctx.strokePath()
        }
        ctx.restoreGState()

        // 4. Click ripples
        if model.cursorStyles.clickRippleEffect, let recordingGeometry = model.recordingGeometry {
            drawClickRipples(ctx, model: model, currentTime: currentTime,
                             recordingGeometry: recordingGeometry,
                             frameContentWidth: frameContentWidth, frameContentHeight: frameContentHeight)
        }

        // 5. Cursor
        if model.cursorStyles.showCursor, let recordingGeometry = model.recordingGeometry {
            drawCursor(ctx, model: model, inputs: inputs, currentTime: currentTime,
                       recordingGeometry: recordingGeometry,
                       frameContentWidth: frameContentWidth, frameContentHeight: frameContentHeight)
        }

        ctx.restoreGState() // end video transform

        // 6. Webcam
        if model.isWebcamVisible, let webcam = inputs.webcamVideo, model.recordingGeometry != nil {
            drawWebcam(ctx, model: model, webcam: webcam, currentTime: currentTime,
                       outputWidth: outputWidth, outputHeight: outputHeight,
                       frameX: frameX, frameY: frameY,
                       frameContentWidth: frameContentWidth, frameContentHeight: frameContentHeight)
        }

        ctx.restoreGState()
    }

    // MARK: - Image helper

    /// Draws a CGImage upright into a top-left rect within the y-flipped context.
    static func drawImageTopLeft(_ ctx: CGContext, _ image: CGImage, in rect: CGRect) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY + rect.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    // MARK: - Background

    static func drawBackground(_ ctx: CGContext, width: Double, height: Double,
                               background: Background, image: CGImage?) {
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        switch background.type {
        case .color:
            ctx.setFillColor(ColorParse.cgColor(background.color ?? "#000000"))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        case .gradient:
            let start = ColorParse.cgColor(background.gradientStart ?? "#000000")
            let end = ColorParse.cgColor(background.gradientEnd ?? "#ffffff")
            let direction = background.gradientDirection ?? "to right"
            if direction.hasPrefix("circle") {
                let colors = (direction == "circle-in" ? [end, start] : [start, end]) as CFArray
                if let g = CGGradient(colorsSpace: srgb, colors: colors, locations: [0, 1]) {
                    let c = CGPoint(x: width / 2, y: height / 2)
                    ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c,
                                           endRadius: max(width, height) / 2, options: [])
                }
            } else {
                let pts = linearGradientPoints(direction, width: width, height: height)
                let colors = [start, end] as CFArray
                if let g = CGGradient(colorsSpace: srgb, colors: colors, locations: [0, 1]) {
                    ctx.drawLinearGradient(g, start: pts.0, end: pts.1, options: [])
                }
            }
        case .image, .wallpaper:
            if let img = image {
                drawCover(ctx, img, width: width, height: height)
            } else {
                ctx.setFillColor(ColorParse.cgColor("oklch(0.2077 0.0398 265.7549)"))
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
    }

    static func linearGradientPoints(_ dir: String, width w: Double, height h: Double) -> (CGPoint, CGPoint) {
        switch dir {
        case "to bottom": return (CGPoint(x: 0, y: 0), CGPoint(x: 0, y: h))
        case "to top": return (CGPoint(x: 0, y: h), CGPoint(x: 0, y: 0))
        case "to right": return (CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0))
        case "to left": return (CGPoint(x: w, y: 0), CGPoint(x: 0, y: 0))
        case "to bottom right": return (CGPoint(x: 0, y: 0), CGPoint(x: w, y: h))
        case "to bottom left": return (CGPoint(x: w, y: 0), CGPoint(x: 0, y: h))
        case "to top right": return (CGPoint(x: 0, y: h), CGPoint(x: w, y: 0))
        case "to top left": return (CGPoint(x: w, y: h), CGPoint(x: 0, y: 0))
        default: return (CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0))
        }
    }

    /// object-fit: cover — crops the source to the canvas aspect, centered.
    static func drawCover(_ ctx: CGContext, _ img: CGImage, width: Double, height: Double) {
        let imgW = Double(img.width), imgH = Double(img.height)
        let imgRatio = imgW / imgH
        let canvasRatio = width / height
        var sx = 0.0, sy = 0.0, sW = imgW, sH = imgH
        if imgRatio > canvasRatio {
            sH = imgH
            sW = sH * canvasRatio
            sx = (imgW - sW) / 2
        } else {
            sW = imgW
            sH = sW / canvasRatio
            sy = (imgH - sH) / 2
        }
        if let cropped = img.cropping(to: CGRect(x: sx, y: sy, width: sW, height: sH)) {
            drawImageTopLeft(ctx, cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    // MARK: - Ripples

    static func drawClickRipples(_ ctx: CGContext, model: SceneModel, currentTime: Double,
                                 recordingGeometry: SizeD, frameContentWidth: Double, frameContentHeight: Double) {
        let cs = model.cursorStyles
        let rippleEasing = Easing.easeOutQuint // "Balanced" ripple in source uses standard ease-out
        let clicks = model.metadata.filter {
            $0.type == .click && ($0.pressed ?? false)
                && currentTime >= $0.timestamp && currentTime < $0.timestamp + cs.clickRippleDuration
        }
        guard let comps = ColorParse.rgbaFloats(cs.clickRippleColor) else { return }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        for click in clicks {
            let progress = (currentTime - click.timestamp) / cs.clickRippleDuration
            let eased = rippleEasing(progress)
            let radius = eased * cs.clickRippleSize
            let opacity = 1 - eased
            let cursorX = (click.x / recordingGeometry.width) * frameContentWidth
            let cursorY = (click.y / recordingGeometry.height) * frameContentHeight
            let color = CGColor(colorSpace: srgb, components: [comps.r, comps.g, comps.b, comps.a * CGFloat(opacity)])!
            ctx.setFillColor(color)
            ctx.fillEllipse(in: CGRect(x: cursorX - radius, y: cursorY - radius, width: radius * 2, height: radius * 2))
        }
    }

    // MARK: - Cursor

    static func drawCursor(_ ctx: CGContext, model: SceneModel, inputs: SceneFrameInputs, currentTime: Double,
                           recordingGeometry: SizeD, frameContentWidth: Double, frameContentHeight: Double) {
        let idx = ZoomTransform.findLastMetadataIndex(model.metadata, currentTime)
        guard idx > -1 else { return }
        let event = model.metadata[idx]
        guard currentTime - event.timestamp < 0.1, let key = event.cursorImageKey,
              let cursor = inputs.cursorBitmaps[key], cursor.width > 0 else { return }

        let cursorX = (event.x / recordingGeometry.width) * frameContentWidth
        let cursorY = (event.y / recordingGeometry.height) * frameContentHeight
        let drawX = (cursorX - cursor.xhot).rounded()
        let drawY = (cursorY - cursor.yhot).rounded()

        ctx.saveGState()

        var cursorScale = 1.0
        let cs = model.cursorStyles
        if cs.clickScaleEffect {
            let recentClick = model.metadata.last {
                $0.type == .click && ($0.pressed ?? false)
                    && $0.timestamp <= currentTime && $0.timestamp > currentTime - cs.clickScaleDuration
            }
            if let click = recentClick {
                let progress = (currentTime - click.timestamp) / cs.clickScaleDuration
                let eased = Easing.curve(cs.clickScaleEasing)(progress)
                cursorScale = 1 - (1 - cs.clickScaleAmount) * sin(eased * .pi)
            }
        }

        if cs.shadowBlur > 0 || cs.shadowOffsetX != 0 || cs.shadowOffsetY != 0 {
            ctx.setShadow(offset: CGSize(width: cs.shadowOffsetX, height: -cs.shadowOffsetY),
                          blur: cs.shadowBlur, color: ColorParse.cgColor(cs.shadowColor))
        }

        if cursorScale != 1 {
            let cx = drawX + cursor.xhot
            let cy = drawY + cursor.yhot
            ctx.translateBy(x: cx, y: cy)
            ctx.scaleBy(x: cursorScale, y: cursorScale)
            ctx.translateBy(x: -cx, y: -cy)
        }

        drawImageTopLeft(ctx, cursor.image, in: CGRect(x: drawX, y: drawY, width: cursor.width, height: cursor.height))
        ctx.restoreGState()
    }

    // MARK: - Webcam

    static func drawWebcam(_ ctx: CGContext, model: SceneModel, webcam: CGImage, currentTime: Double,
                           outputWidth: Double, outputHeight: Double, frameX: Double, frameY: Double,
                           frameContentWidth: Double, frameContentHeight: Double) {
        guard let recordingGeometry = model.recordingGeometry else { return }
        let ws = model.webcamStyles

        // scale-on-zoom
        var finalWebcamScale = 1.0
        if ws.scaleOnZoom {
            let active = model.zoomRegions.values.sorted { $0.startTime < $1.startTime }
                .first { currentTime >= $0.startTime && currentTime < $0.startTime + $0.duration }
            if let r = active {
                let zoomInEnd = r.startTime + r.transitionDuration
                let zoomOutStart = r.startTime + r.duration - r.transitionDuration
                let easing = Easing.curve(r.easing)
                if currentTime < zoomInEnd {
                    finalWebcamScale = lerp(1, Defaults.Camera.scaleOnZoomAmount, easing((currentTime - r.startTime) / r.transitionDuration))
                } else if currentTime >= zoomOutStart {
                    finalWebcamScale = lerp(Defaults.Camera.scaleOnZoomAmount, 1, easing((currentTime - zoomOutStart) / r.transitionDuration))
                } else {
                    finalWebcamScale = Defaults.Camera.scaleOnZoomAmount
                }
            }
        }

        let baseSize = min(outputWidth, outputHeight)
        var initialW: Double, initialH: Double
        if ws.shape == .rectangle {
            initialW = baseSize * (ws.size / 100)
            initialH = initialW * (9.0 / 16.0)
        } else {
            initialW = baseSize * (ws.size / 100)
            initialH = initialW
        }

        let originalPos = model.webcamPosition
        var currentPos = originalPos
        var previousPos = originalPos
        var timeOfChange = 0.0

        if ws.smartPosition {
            func targetPos(at time: Double) -> WebcamPos {
                let originalRect = Geometry.webcamRect(for: originalPos, width: initialW, height: initialH,
                                                       outputWidth: outputWidth, outputHeight: outputHeight)
                let fi = ZoomTransform.findLastMetadataIndex(model.metadata, time + Defaults.Camera.smartPositionLookahead)
                if fi > -1 {
                    let e = model.metadata[fi]
                    let cx = (e.x / recordingGeometry.width) * frameContentWidth + frameX
                    let cy = (e.y / recordingGeometry.height) * frameContentHeight + frameY
                    if pointInRect(cx, cy, originalRect) {
                        let (adj1, adj2) = Geometry.adjacentPositions(originalPos)
                        let adj1Rect = Geometry.webcamRect(for: adj1, width: initialW, height: initialH,
                                                           outputWidth: outputWidth, outputHeight: outputHeight)
                        return !pointInRect(cx, cy, adj1Rect) ? adj1 : adj2
                    }
                }
                return originalPos
            }
            currentPos = targetPos(at: currentTime)
            let interval = 0.05
            var t = currentTime
            while t >= 0 {
                let posAtT = targetPos(at: t)
                if posAtT != currentPos {
                    previousPos = posAtT
                    timeOfChange = t + interval
                    break
                }
                if t == 0 {
                    previousPos = currentPos
                    timeOfChange = 0
                }
                t -= interval
            }
        }

        let transitionDuration = Defaults.Camera.smartPositionTransition
        var progress = 1.0
        if previousPos != currentPos && currentTime - timeOfChange < transitionDuration {
            progress = (currentTime - timeOfChange) / transitionDuration
        }
        let eased = Easing.curve(Defaults.Camera.smartPositionEasing)(min(1, progress))

        let startRect = Geometry.webcamRect(for: previousPos, width: initialW, height: initialH, outputWidth: outputWidth, outputHeight: outputHeight)
        let targetRect = Geometry.webcamRect(for: currentPos, width: initialW, height: initialH, outputWidth: outputWidth, outputHeight: outputHeight)
        let baseX = lerp(startRect.x, targetRect.x, eased)
        let baseY = lerp(startRect.y, targetRect.y, eased)

        let webcamWidth = initialW * finalWebcamScale
        let webcamHeight = initialH * finalWebcamScale
        var webcamX = baseX
        var webcamY = baseY
        if originalPos.rawValue.contains("right") {
            webcamX += initialW - webcamWidth
        } else if originalPos == .topCenter || originalPos == .bottomCenter {
            webcamX += (initialW - webcamWidth) / 2
        }
        if originalPos.rawValue.contains("bottom") {
            webcamY += initialH - webcamHeight
        } else if originalPos == .leftCenter || originalPos == .rightCenter {
            webcamY += (initialH - webcamHeight) / 2
        }

        let maxRadius = min(webcamWidth, webcamHeight) / 2
        let webcamRadius = ws.shape == .circle ? maxRadius : maxRadius * (ws.borderRadius / 50)

        // Shadow
        if ws.shadowBlur > 0 {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: ws.shadowOffsetX, height: -ws.shadowOffsetY),
                          blur: ws.shadowBlur, color: ColorParse.cgColor(ws.shadowColor))
            let p = CGPath(roundedRect: CGRect(x: webcamX, y: webcamY, width: webcamWidth, height: webcamHeight),
                           cornerWidth: webcamRadius, cornerHeight: webcamRadius, transform: nil)
            ctx.addPath(p)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fillPath()
            ctx.restoreGState()
        }

        // Cover-crop source
        let vidW = Double(webcam.width), vidH = Double(webcam.height)
        let webcamAR = vidW / vidH
        let targetAR = webcamWidth / webcamHeight
        var sx = 0.0, sy = 0.0, sW = vidW, sH = vidH
        if webcamAR > targetAR {
            sW = vidH * targetAR
            sx = (vidW - sW) / 2
        } else {
            sH = vidW / targetAR
            sy = (vidH - sH) / 2
        }

        ctx.saveGState()
        if ws.isFlipped {
            ctx.translateBy(x: outputWidth, y: 0)
            ctx.scaleBy(x: -1, y: 1)
        }
        let drawX = ws.isFlipped ? outputWidth - webcamX - webcamWidth : webcamX
        let clipPath = CGPath(roundedRect: CGRect(x: drawX, y: webcamY, width: webcamWidth, height: webcamHeight),
                              cornerWidth: webcamRadius, cornerHeight: webcamRadius, transform: nil)
        ctx.addPath(clipPath)
        ctx.clip()
        if let cropped = webcam.cropping(to: CGRect(x: sx, y: sy, width: sW, height: sH)) {
            drawImageTopLeft(ctx, cropped, in: CGRect(x: drawX, y: webcamY, width: webcamWidth, height: webcamHeight))
        }
        ctx.restoreGState()
    }

    static func pointInRect(_ x: Double, _ y: Double, _ r: RectD) -> Bool {
        x >= r.x && x <= r.x + r.width && y >= r.y && y <= r.y + r.height
    }
}
