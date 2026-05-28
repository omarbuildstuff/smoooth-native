import XCTest
import CoreGraphics
@testable import SmooothCore

final class SceneRendererTests: XCTestCase {

    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    private func solidImage(r: Double, g: Double, b: Double, w: Int = 16, h: Int = 16) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    private func makeModel(background: Background, webcam: Bool = false, cursor: Bool = false,
                           zoom: Bool = false) -> SceneModel {
        let fs = FrameStyles(padding: 5, background: background, borderRadius: 0, shadowBlur: 0,
                             shadowOffsetX: 0, shadowOffsetY: 0, shadowColor: "rgba(0,0,0,0.8)",
                             borderWidth: 0, borderColor: "rgba(255,255,255,0.2)")
        let cs = CursorStyles(showCursor: cursor, shadowBlur: 6, shadowOffsetX: 3, shadowOffsetY: 3,
                              shadowColor: "rgba(0,0,0,0.4)", clickRippleEffect: true,
                              clickRippleColor: "rgba(255,255,255,0.8)", clickRippleSize: 30,
                              clickRippleDuration: 0.5, clickScaleEffect: true, clickScaleAmount: 0.8,
                              clickScaleDuration: 0.4, clickScaleEasing: "Balanced")
        let ws = WebcamStyles(shape: .circle, borderRadius: 35, size: 40, shadowBlur: 20,
                              shadowOffsetX: 0, shadowOffsetY: 10, shadowColor: "rgba(0,0,0,0.4)",
                              isFlipped: false, scaleOnZoom: true, smartPosition: true)
        var regions: [String: ZoomRegion] = [:]
        if zoom {
            regions["z"] = ZoomRegion(id: "z", startTime: 0, duration: 3, zoomLevel: 2, easing: "Balanced",
                                      transitionDuration: 1, targetX: 0, targetY: 0, mode: .auto, zIndex: 10)
        }
        let meta = [
            MetaDataItem(timestamp: 0, x: 960, y: 540, type: .move, cursorImageKey: "arrow"),
            MetaDataItem(timestamp: 0.05, x: 970, y: 545, type: .click, pressed: true, cursorImageKey: "arrow"),
        ]
        return SceneModel(frameStyles: fs, videoDimensions: SizeD(width: 1920, height: 1080),
                          recordingGeometry: SizeD(width: 1920, height: 1080), zoomRegions: regions,
                          metadata: meta, cursorStyles: cs, isWebcamVisible: webcam,
                          webcamPosition: .bottomRight, webcamStyles: ws)
    }

    /// Renders into an owned buffer and samples flip-invariant points.
    func testBackgroundAndVideoComposite() {
        let w = 1280, h = 720
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: w * h * 4, alignment: 1)
        defer { ptr.deallocate() }
        let ctx = CGContext(data: ptr, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

        let model = makeModel(background: Background(type: .color, color: "#ff0000"))
        let inputs = SceneFrameInputs(mainVideo: solidImage(r: 0, g: 1, b: 0))
        SceneRenderer.render(into: ctx, model: model, inputs: inputs, currentTime: 0,
                             outputWidth: Double(w), outputHeight: Double(h))

        let bytes = ptr.bindMemory(to: UInt8.self, capacity: w * h * 4)
        func px(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
            let o = y * w * 4 + x * 4
            return (bytes[o], bytes[o + 1], bytes[o + 2])
        }
        // Center is inside the centered video → green.
        let c = px(w / 2, h / 2)
        XCTAssertGreaterThan(c.g, 200, "center green")
        XCTAssertLessThan(c.r, 60, "center not red")
        // All four corners are padding → red background (flip-invariant).
        for (x, y) in [(6, 6), (w - 6, 6), (6, h - 6), (w - 6, h - 6)] {
            let p = px(x, y)
            XCTAssertGreaterThan(p.r, 200, "corner red @\(x),\(y)")
            XCTAssertLessThan(p.g, 60, "corner not green @\(x),\(y)")
        }
    }

    func testGradientBackgroundRendersImage() {
        let bg = Background(type: .gradient, gradientStart: "#000000", gradientEnd: "#ffffff", gradientDirection: "to bottom right")
        let img = SceneRenderer.renderImage(model: makeModel(background: bg),
                                            inputs: SceneFrameInputs(mainVideo: solidImage(r: 0, g: 0, b: 1)),
                                            currentTime: 0, outputSize: SizeI(width: 640, height: 360))
        XCTAssertNotNil(img)
        XCTAssertEqual(img?.width, 640)
        XCTAssertEqual(img?.height, 360)
    }

    func testWebcamCursorZoomPathsDoNotCrash() {
        let model = makeModel(background: Background(type: .color, color: "#222222"),
                              webcam: true, cursor: true, zoom: true)
        let inputs = SceneFrameInputs(
            mainVideo: solidImage(r: 0.2, g: 0.4, b: 0.8, w: 64, h: 36),
            webcamVideo: solidImage(r: 0.9, g: 0.7, b: 0.5, w: 32, h: 32),
            cursorBitmaps: ["arrow": CursorBitmap(image: solidImage(r: 1, g: 1, b: 1, w: 8, h: 8),
                                                  width: 8, height: 8, xhot: 0, yhot: 0)]
        )
        for t in stride(from: 0.0, through: 3.0, by: 0.25) {
            let img = SceneRenderer.renderImage(model: model, inputs: inputs, currentTime: t,
                                                outputSize: SizeI(width: 480, height: 270))
            XCTAssertNotNil(img, "frame @t=\(t)")
        }
    }
}
