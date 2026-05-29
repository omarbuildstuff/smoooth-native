import SwiftUI
import AppKit
import AVFoundation
import CoreImage
import SmooothCore

/// GPU-composited live preview. The heavy parts (background, rounded frame, shadow,
/// border) are CALayers configured only when style changes; the zoom/pan is applied
/// as a CATransform3D on the frame layer EACH display tick (GPU, ~free), and the
/// video/webcam layers just swap `contents` at video rate. This replaces the
/// per-frame CPU CGContext composite (which capped at ~19–32 fps → "saccadé").
///
/// Export still uses SceneRenderer (CGContext) for exact, offline-quality output;
/// both share SceneLayout + ZoomTransform so preview matches the export.
struct LayerPreview: NSViewRepresentable {
    let model: EditorModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> PreviewLayerView {
        let v = PreviewLayerView()
        context.coordinator.attach(to: v)
        return v
    }
    func updateNSView(_ nsView: PreviewLayerView, context: Context) {}
    static func dismantleNSView(_ nsView: PreviewLayerView, coordinator: Coordinator) { coordinator.teardown() }

    @MainActor
    final class Coordinator {
        private let model: EditorModel
        private weak var view: PreviewLayerView?
        private var link: CADisplayLink?

        // Players
        private var mainPlayer: AVPlayer?
        private var mainOutput: AVPlayerItemVideoOutput?
        private var webcamPlayer: AVPlayer?
        private var webcamOutput: AVPlayerItemVideoOutput?
        private var cfgVideoURL: URL?
        private var cfgWebcamURL: URL?
        private var lastClockWriteback = -1.0
        private let ci = CIContext(options: [.useSoftwareRenderer: false])

        // Layers
        private let canvas = CALayer()          // output rect; background lives here
        private let shadowLayer = CALayer()      // carries the frame shadow (zoomed)
        private let frameClip = CALayer()        // rounded, clips video+cursor (zoomed)
        private let videoLayer = CALayer()
        private let cursorLayer = CALayer()
        private let webcamLayer = CALayer()      // output space (not zoomed)
        private var gradientLayer: CAGradientLayer?

        // Cached style signature to avoid reconfiguring static layers every frame.
        private var styleKey = ""
        private var cursorKey = ""

        init(model: EditorModel) { self.model = model }

        func attach(to v: PreviewLayerView) {
            view = v
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.black.cgColor
            // Top-left origin so all math matches SceneLayout/ZoomTransform.
            canvas.isGeometryFlipped = true
            canvas.masksToBounds = true
            v.layer?.addSublayer(canvas)

            shadowLayer.backgroundColor = NSColor.clear.cgColor
            frameClip.masksToBounds = true
            frameClip.addSublayer(videoLayer)
            frameClip.addSublayer(cursorLayer)
            videoLayer.contentsGravity = .resize
            cursorLayer.contentsGravity = .resizeAspect
            webcamLayer.masksToBounds = true
            canvas.addSublayer(shadowLayer)
            canvas.addSublayer(frameClip)
            canvas.addSublayer(webcamLayer)

            let dl = v.displayLink(target: self, selector: #selector(tick))
            dl.add(to: .main, forMode: .common)
            link = dl
        }

        func teardown() { link?.invalidate(); link = nil; mainPlayer?.pause(); webcamPlayer?.pause() }

        @objc private func tick() { render() }

        private func configurePlayers() {
            if model.videoURL != cfgVideoURL {
                cfgVideoURL = model.videoURL
                if let url = model.videoURL {
                    let item = AVPlayerItem(url: url)
                    let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                    item.add(out); let p = AVPlayer(playerItem: item); p.actionAtItemEnd = .pause
                    mainPlayer = p; mainOutput = out
                } else { mainPlayer = nil; mainOutput = nil }
            }
            if model.webcamVideoURL != cfgWebcamURL {
                cfgWebcamURL = model.webcamVideoURL
                if let url = model.webcamVideoURL {
                    let item = AVPlayerItem(url: url)
                    let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                    item.add(out); let p = AVPlayer(playerItem: item); p.isMuted = true
                    webcamPlayer = p; webcamOutput = out
                } else { webcamPlayer = nil; webcamOutput = nil }
            }
        }

        private func render() {
            configurePlayers()
            guard let view, let player = mainPlayer else { return }
            let scale = view.window?.backingScaleFactor ?? 2

            // --- Clock (same logic as before) ---
            player.volume = Float(model.isMuted ? 0 : model.volume)
            if model.isPlaying {
                let target = CMTime(seconds: model.currentTime, preferredTimescale: 600)
                if player.timeControlStatus != .playing {
                    player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero); player.play()
                    webcamPlayer?.seek(to: target); webcamPlayer?.play()
                } else if abs(model.currentTime - lastClockWriteback) > 0.1 {
                    player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero); webcamPlayer?.seek(to: target)
                }
                let t = CMTimeGetSeconds(player.currentTime())
                model.currentTime = t; lastClockWriteback = t
                if t >= model.duration, model.duration > 0 { model.pause(); player.pause(); webcamPlayer?.pause() }
            } else {
                if player.timeControlStatus == .playing { player.pause(); webcamPlayer?.pause() }
                let target = CMTime(seconds: model.currentTime, preferredTimescale: 600)
                if abs(CMTimeGetSeconds(player.currentTime()) - model.currentTime) > 0.033 {
                    player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                    webcamPlayer?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }

            // --- Pull latest video frames (cheap; convert only when new) ---
            let itemTime = player.currentTime()
            if let out = mainOutput, out.hasNewPixelBuffer(forItemTime: itemTime),
               let pb = out.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil),
               let cg = cg(pb) {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                videoLayer.contents = cg
                CATransaction.commit()
            }
            if let out = webcamOutput, let wp = webcamPlayer, out.hasNewPixelBuffer(forItemTime: wp.currentTime()),
               let pb = out.copyPixelBuffer(forItemTime: wp.currentTime(), itemTimeForDisplay: nil),
               let cg = cg(pb) {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                webcamLayer.contents = cg
                CATransaction.commit()
            }

            layout(scale: scale)
        }

        private func cg(_ pb: CVPixelBuffer) -> CGImage? {
            let img = CIImage(cvPixelBuffer: pb)
            return ci.createCGImage(img, from: img.extent)
        }

        /// Positions layers each tick. Static layers reconfigured only on style change.
        private func layout(scale: CGFloat) {
            guard let view else { return }
            let viewW = view.bounds.width, viewH = view.bounds.height
            guard viewW > 1, viewH > 1 else { return }

            // Output rect = aspect-fit the chosen ratio into the view (letterboxed).
            let comps = model.aspectRatio.components
            let ar = comps.w / comps.h
            var outW = viewW, outH = viewW / ar
            if outH > viewH { outH = viewH; outW = viewH * ar }
            let outX = ((viewW - outW) / 2).rounded(), outY = ((viewH - outH) / 2).rounded()

            CATransaction.begin(); CATransaction.setDisableActions(true)
            canvas.frame = CGRect(x: outX, y: outY, width: outW, height: outH)
            canvas.contentsScale = scale

            let fs = model.frameStyles
            let lay = SceneLayout.compute(outputWidth: outW, outputHeight: outH,
                                          videoDimensions: model.videoDimensions, padding: fs.padding)
            let contentRect = CGRect(x: lay.frameX, y: lay.frameY, width: lay.frameContentWidth, height: lay.frameContentHeight)
            let radius = min(fs.borderRadius, min(lay.frameContentWidth, lay.frameContentHeight) / 2)

            configureBackground(outW: outW, outH: outH, scale: scale)
            configureStaticFrame(contentRect: contentRect, radius: radius, fs: fs, scale: scale)
            updateCursor(scale: scale, contentRect: contentRect)

            // --- Zoom/pan transform on the frame + shadow (GPU) ---
            let recGeo = model.recordingGeometry.map { SizeD(width: $0.width, height: $0.height) } ?? model.videoDimensions
            let zt = ZoomTransform.calculate(currentTime: model.currentTime, zoomRegions: model.zoomRegions,
                                             metadata: model.metadata, recordingGeometry: recGeo,
                                             frameContent: SizeD(width: lay.frameContentWidth, height: lay.frameContentHeight))
            applyZoom(zt, contentRect: contentRect)

            updateWebcam(outW: outW, outH: outH, lay: lay, zt: zt, scale: scale)
            CATransaction.commit()
        }

        private func applyZoom(_ zt: ZoomTransformResult, contentRect: CGRect) {
            // anchor at the zoom origin (fraction); position so that, at scale s, the
            // origin lands at frameXY + originPx + s*(tx,ty) — matching SceneRenderer.
            let s = zt.scale
            let originPxX = zt.originX * contentRect.width
            let originPxY = zt.originY * contentRect.height
            for l in [shadowLayer, frameClip] {
                l.bounds = CGRect(x: 0, y: 0, width: contentRect.width, height: contentRect.height)
                l.anchorPoint = CGPoint(x: zt.originX, y: zt.originY)
                l.position = CGPoint(x: contentRect.minX + originPxX + s * zt.translateX,
                                     y: contentRect.minY + originPxY + s * zt.translateY)
                l.transform = CATransform3DMakeScale(s, s, 1)
            }
        }

        private func configureBackground(outW: Double, outH: Double, scale: CGFloat) {
            let bg = model.frameStyles.background
            switch bg.type {
            case .color:
                gradientLayer?.removeFromSuperlayer(); gradientLayer = nil
                canvas.contents = nil
                canvas.backgroundColor = ColorParse.cgColor(bg.color ?? "#101820")
            case .gradient:
                canvas.contents = nil; canvas.backgroundColor = NSColor.clear.cgColor
                let g = gradientLayer ?? { let l = CAGradientLayer(); canvas.insertSublayer(l, at: 0); gradientLayer = l; return l }()
                g.frame = CGRect(x: 0, y: 0, width: outW, height: outH)
                g.colors = [ColorParse.cgColor(bg.gradientStart ?? "#4f46e5"), ColorParse.cgColor(bg.gradientEnd ?? "#0ea5e9")]
                let dir = bg.gradientDirection ?? "to bottom right"
                let (sp, ep) = gradientPoints(dir)
                g.startPoint = sp; g.endPoint = ep
            case .image, .wallpaper:
                gradientLayer?.removeFromSuperlayer(); gradientLayer = nil
                canvas.backgroundColor = NSColor.black.cgColor
                canvas.contentsGravity = .resizeAspectFill
                canvas.contents = model.backgroundImage
            }
        }

        private func configureStaticFrame(contentRect: CGRect, radius: Double, fs: FrameStyles, scale: CGFloat) {
            let key = "\(Int(contentRect.width))x\(Int(contentRect.height))-\(radius)-\(fs.borderWidth)-\(fs.borderColor)-\(fs.shadowBlur)-\(fs.shadowOffsetX)-\(fs.shadowOffsetY)-\(fs.shadowColor)-\(scale)"
            videoLayer.frame = CGRect(x: 0, y: 0, width: contentRect.width, height: contentRect.height)
            videoLayer.contentsScale = scale
            if key == styleKey { return }
            styleKey = key
            frameClip.cornerRadius = radius
            frameClip.contentsScale = scale
            // frameClip (masksToBounds) clips the video to the rounded rect.
            // border on the clip layer (on top of video)
            frameClip.borderWidth = fs.borderWidth
            frameClip.borderColor = ColorParse.cgColor(fs.borderColor)
            // shadow on the shadow layer behind
            if fs.shadowBlur > 0 {
                shadowLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
                shadowLayer.cornerRadius = radius
                shadowLayer.shadowColor = ColorParse.cgColor(fs.shadowColor)
                shadowLayer.shadowOpacity = 1
                shadowLayer.shadowRadius = fs.shadowBlur / 2     // CG blur ≈ 2×layer shadowRadius
                shadowLayer.shadowOffset = CGSize(width: fs.shadowOffsetX, height: fs.shadowOffsetY)
            } else {
                shadowLayer.shadowOpacity = 0; shadowLayer.backgroundColor = NSColor.clear.cgColor
            }
        }

        private func updateCursor(scale: CGFloat, contentRect: CGRect) {
            let cs = model.cursorStyles
            guard cs.showCursor, let recGeo = model.recordingGeometry else { cursorLayer.isHidden = true; return }
            let idx = ZoomTransform.findLastMetadataIndex(model.metadata, model.currentTime)
            guard idx > -1 else { cursorLayer.isHidden = true; return }
            let e = model.metadata[idx]
            let cx = (e.x / recGeo.width) * contentRect.width
            let cy = (e.y / recGeo.height) * contentRect.height

            // contents per theme (cached by key)
            let key = "\(cs.theme.rawValue)-\(Int(cs.size))-\(e.cursorImageKey ?? "")-\(scale)"
            if key != cursorKey {
                cursorKey = key
                cursorLayer.contentsScale = scale
                if cs.theme == .system, let k = e.cursorImageKey, let bmp = model.cursorBitmaps[k] {
                    cursorLayer.contents = bmp.image
                    cursorLayer.bounds = CGRect(x: 0, y: 0, width: bmp.width, height: bmp.height)
                    cursorLayer.anchorPoint = CGPoint(x: bmp.xhot / max(1, bmp.width), y: bmp.yhot / max(1, bmp.height))
                } else if cs.theme == .bayzo, let bmp = model.customCursor {
                    // Scale to target height = size*2.2 (matches SceneRenderer export).
                    let targetH = cs.size * 2.2
                    let s = targetH / max(1, bmp.height)
                    cursorLayer.contents = bmp.image
                    cursorLayer.bounds = CGRect(x: 0, y: 0, width: bmp.width * s, height: bmp.height * s)
                    cursorLayer.anchorPoint = CGPoint(x: bmp.xhot / max(1, bmp.width), y: bmp.yhot / max(1, bmp.height))
                } else if cs.theme == .classic || cs.theme == .dot || cs.theme == .highlight {
                    let (img, anchor, size) = SyntheticCursor.image(theme: cs.theme, size: cs.size, scale: scale)
                    cursorLayer.contents = img
                    cursorLayer.bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
                    cursorLayer.anchorPoint = anchor
                } else {
                    cursorLayer.isHidden = true; return
                }
            }
            cursorLayer.isHidden = false
            // click-scale
            var sc = 1.0
            if cs.clickScaleEffect, let click = model.metadata.last(where: {
                $0.type == .click && ($0.pressed ?? false) && $0.timestamp <= model.currentTime && $0.timestamp > model.currentTime - cs.clickScaleDuration }) {
                let p = (model.currentTime - click.timestamp) / cs.clickScaleDuration
                sc = 1 - (1 - cs.clickScaleAmount) * sin(Easing.curve(cs.clickScaleEasing)(p) * .pi)
            }
            cursorLayer.position = CGPoint(x: cx, y: cy)
            cursorLayer.transform = CATransform3DMakeScale(sc, sc, 1)
        }

        private func updateWebcam(outW: Double, outH: Double, lay: SceneLayout, zt: ZoomTransformResult, scale: CGFloat) {
            guard model.isWebcamVisible, model.webcamVideoURL != nil, webcamLayer.contents != nil else { webcamLayer.isHidden = true; return }
            webcamLayer.isHidden = false
            webcamLayer.contentsScale = scale
            let ws = model.webcamStyles
            let baseSize = min(outW, outH)
            var w = baseSize * (ws.size / 100), h = ws.shape == .rectangle ? w * 9/16 : w
            // scale-on-zoom
            if ws.scaleOnZoom, zt.scale != 1 {
                let amt = Defaults.Camera.scaleOnZoomAmount
                // approximate: blend toward amt by how far into the zoom we are
                let f = (zt.scale - 1) / max(0.0001, (model.zoomRegions.values.first?.zoomLevel ?? 2) - 1)
                let m = 1 - (1 - amt) * min(1, max(0, f))
                w *= m; h *= m
            }
            let rect = Geometry.webcamRect(for: model.webcamPosition, width: w, height: h, outputWidth: outW, outputHeight: outH)
            webcamLayer.frame = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
            webcamLayer.contentsGravity = .resizeAspectFill
            let maxR = min(w, h) / 2
            webcamLayer.cornerRadius = ws.shape == .circle ? maxR : maxR * (ws.borderRadius / 50)
            if ws.shadowBlur > 0 {
                webcamLayer.shadowColor = ColorParse.cgColor(ws.shadowColor)
                webcamLayer.shadowOpacity = 1; webcamLayer.shadowRadius = ws.shadowBlur / 2
                webcamLayer.shadowOffset = CGSize(width: ws.shadowOffsetX, height: ws.shadowOffsetY)
            } else { webcamLayer.shadowOpacity = 0 }
        }

        private func gradientPoints(_ dir: String) -> (CGPoint, CGPoint) {
            // canvas is geometry-flipped (top-left), CAGradientLayer uses unit coords (0,0)=bottomLeft normally;
            // with isGeometryFlipped the y is flipped too, so treat (0,0)=top-left.
            switch dir {
            case "to bottom": return (CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1))
            case "to top": return (CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0))
            case "to right": return (CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5))
            case "to left": return (CGPoint(x: 1, y: 0.5), CGPoint(x: 0, y: 0.5))
            case "to bottom left": return (CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1))
            case "to top right": return (CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 0))
            case "to top left": return (CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 0))
            default: return (CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)) // to bottom right
            }
        }
    }
}

final class PreviewLayerView: NSView {
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); layer?.sublayers?.first?.setNeedsLayout() }
}

/// Renders the synthetic cursor themes to a CGImage once (cached by the caller).
enum SyntheticCursor {
    /// Returns (image, anchorPoint fraction for the hotspot, size in points).
    static func image(theme: CursorTheme, size: Double, scale: CGFloat) -> (CGImage, CGPoint, CGSize) {
        let pad = size * 1.4
        let dim = Int((size + pad) * scale)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: dim, height: dim, bitsPerComponent: 8, bytesPerRow: 0,
                            space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        let boxPts = (size + pad)
        let cx = boxPts / 2, cy = boxPts / 2
        // Draw with SceneRenderer's synthetic routine, centered; for classic the tip is at center.
        SceneRenderer.drawSyntheticCursor(ctx, theme: theme, x: cx, y: cy, size: size)
        let img = ctx.makeImage()!
        // anchor: classic tip is at center → (0.5,0.5); dot/highlight centered → (0.5,0.5)
        return (img, CGPoint(x: 0.5, y: 0.5), CGSize(width: boxPts, height: boxPts))
    }
}
