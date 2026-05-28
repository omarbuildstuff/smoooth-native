import XCTest
import AVFoundation
import CoreGraphics
import ImageIO
@testable import SmooothCore

final class ExportTests: XCTestCase {
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    private func solidCG(_ r: Double, _ g: Double, _ b: Double, _ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    /// Writes a small valid H.264 mp4 of solid frames to use as an export source.
    private func writeSampleVideo(to url: URL, width: Int, height: Int, fps: Int, seconds: Double) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        XCTAssertTrue(writer.canAdd(input)); writer.add(input)
        XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        let total = Int(seconds * Double(fps))
        for i in 0..<total {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            let hue = Double(i) / Double(max(1, total))
            let cg = solidCG(hue, 1 - hue, 0.4, width, height)
            guard let pool = adaptor.pixelBufferPool, let pb = VideoExporter.makePixelBuffer(from: cg, pool: pool) else {
                XCTFail("no pool"); return
            }
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in writer.finishWriting { c.resume() } }
        XCTAssertEqual(writer.status, .completed, "sample writer: \(String(describing: writer.error))")
    }

    private func model(srcW: Double, srcH: Double) -> SceneModel {
        let fs = FrameStyles(padding: 5, background: Background(type: .color, color: "#101820"),
                             borderRadius: 16, shadowBlur: 0, shadowOffsetX: 0, shadowOffsetY: 0,
                             shadowColor: "rgba(0,0,0,0.8)", borderWidth: 0, borderColor: "rgba(255,255,255,0.2)")
        let cs = CursorStyles(showCursor: false, shadowBlur: 0, shadowOffsetX: 0, shadowOffsetY: 0,
                              shadowColor: "rgba(0,0,0,0.4)", clickRippleEffect: false, clickRippleColor: "rgba(255,255,255,0.8)",
                              clickRippleSize: 30, clickRippleDuration: 0.5, clickScaleEffect: false,
                              clickScaleAmount: 0.8, clickScaleDuration: 0.4, clickScaleEasing: "Balanced")
        let ws = WebcamStyles(shape: .circle, borderRadius: 35, size: 40, shadowBlur: 0, shadowOffsetX: 0,
                              shadowOffsetY: 0, shadowColor: "rgba(0,0,0,0.4)", isFlipped: false,
                              scaleOnZoom: false, smartPosition: false)
        return SceneModel(frameStyles: fs, videoDimensions: SizeD(width: srcW, height: srcH),
                          recordingGeometry: SizeD(width: srcW, height: srcH), zoomRegions: [:],
                          metadata: [], cursorStyles: cs, isWebcamVisible: false,
                          webcamPosition: .bottomRight, webcamStyles: ws)
    }

    private func assetDurationAndSize(_ url: URL) async throws -> (dur: Double, size: CGSize) {
        let asset = AVURLAsset(url: url)
        let dur = try await CMTimeGetSeconds(asset.load(.duration))
        let track = try await asset.loadTracks(withMediaType: .video).first
        let size = try await track?.load(.naturalSize) ?? .zero
        return (dur, size)
    }

    func testMP4ExportDimensionsAndDuration() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let src = tmp.appendingPathComponent("smoooth-src-\(UUID().uuidString).mp4")
        let out = tmp.appendingPathComponent("smoooth-out-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: out) }
        try await writeSampleVideo(to: src, width: 320, height: 240, fps: 30, seconds: 1.0)

        let job = VideoExporter.Job(mainVideoURL: src, model: model(srcW: 320, srcH: 240),
                                    duration: 1.0, aspectRatio: .r16x9,
                                    settings: ExportSettings(resolution: "1080p", fps: 30, format: .mp4),
                                    outputURL: out)
        _ = try await VideoExporter().export(job)

        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        let (dur, size) = try await assetDurationAndSize(out)
        XCTAssertEqual(size.width, 1920, accuracy: 1)
        XCTAssertEqual(size.height, 1080, accuracy: 1)
        XCTAssertEqual(dur, 1.0, accuracy: 0.2, "exported duration")
    }

    func testCutRegionShortensDuration() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let src = tmp.appendingPathComponent("smoooth-src-\(UUID().uuidString).mp4")
        let out = tmp.appendingPathComponent("smoooth-out-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: out) }
        try await writeSampleVideo(to: src, width: 320, height: 240, fps: 30, seconds: 1.0)

        let cuts = ["c": CutRegion(id: "c", startTime: 0.3, duration: 0.3, zIndex: 10)]
        let job = VideoExporter.Job(mainVideoURL: src, model: model(srcW: 320, srcH: 240),
                                    duration: 1.0, cutRegions: cuts, aspectRatio: .r16x9,
                                    settings: ExportSettings(resolution: "720p", fps: 30, format: .mp4),
                                    outputURL: out)
        _ = try await VideoExporter().export(job)
        let (dur, _) = try await assetDurationAndSize(out)
        XCTAssertEqual(dur, 0.7, accuracy: 0.2, "duration after 0.3s cut")
    }

    func testGifExport() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let src = tmp.appendingPathComponent("smoooth-src-\(UUID().uuidString).mp4")
        let out = tmp.appendingPathComponent("smoooth-out-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: out) }
        try await writeSampleVideo(to: src, width: 320, height: 240, fps: 30, seconds: 0.5)

        let job = VideoExporter.Job(mainVideoURL: src, model: model(srcW: 320, srcH: 240),
                                    duration: 0.5, aspectRatio: .r16x9,
                                    settings: ExportSettings(resolution: "720p", fps: 15, format: .gif),
                                    outputURL: out)
        _ = try await VideoExporter().export(job)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        let imgSrc = CGImageSourceCreateWithURL(out as CFURL, nil)
        XCTAssertNotNil(imgSrc)
        XCTAssertGreaterThan(CGImageSourceGetCount(imgSrc!), 1, "gif has multiple frames")
    }
}
