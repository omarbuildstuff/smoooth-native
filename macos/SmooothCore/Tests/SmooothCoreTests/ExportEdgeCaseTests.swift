import XCTest
import AVFoundation
import CoreGraphics
import ImageIO
@testable import SmooothCore

/// Stress / edge-case coverage for the seek-driven export pipeline. Mirrors the
/// `writeSampleVideo` helper pattern from ExportTests.swift but exercises cut/speed
/// region combinations, alternate resolutions/aspect ratios, cancel-reuse, and gif
/// frame counts.
final class ExportEdgeCaseTests: XCTestCase {
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

    private func tmpURLs(_ ext: String) -> (src: URL, out: URL) {
        let tmp = FileManager.default.temporaryDirectory
        return (tmp.appendingPathComponent("smoooth-src-\(UUID().uuidString).mp4"),
                tmp.appendingPathComponent("smoooth-out-\(UUID().uuidString).\(ext)"))
    }

    // MARK: - (a) Cut region at t=0

    func testCutAtTimeZero() async throws {
        let (src, out) = tmpURLs("mp4")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: out) }
        try await writeSampleVideo(to: src, width: 320, height: 240, fps: 30, seconds: 1.0)

        // A 0.4s cut anchored at the very start of the timeline.
        let cuts = ["c": CutRegion(id: "c", startTime: 0.0, duration: 0.4, zIndex: 10)]
        // Sanity-check the pure remap: export t=0 should map past the cut to source 0.4.
        let mapped0 = TimeRemap.mapExportTimeToSourceTime(0, duration: 1.0, cutRegions: cuts, speedRegions: [:])
        XCTAssertEqual(mapped0, 0.4, accuracy: 1e-9, "export t=0 should land just after the leading cut")

        let job = VideoExporter.Job(mainVideoURL: src, model: model(srcW: 320, srcH: 240),
                                    duration: 1.0, cutRegions: cuts, aspectRatio: .r16x9,
                                    settings: ExportSettings(resolution: "720p", fps: 30, format: .mp4),
                                    outputURL: out)
        _ = try await VideoExporter().export(job)
        let (dur, _) = try await assetDurationAndSize(out)
        XCTAssertEqual(dur, 0.6, accuracy: 0.2, "duration after a 0.4s leading cut")
    }

    // MARK: - (b) Overlapping + adjacent cut/speed regions

    /// Adjacent (touching, non-overlapping) cut then speed region. These are the
    /// common, well-defined case and the naive duration formula is exact here.
    func testAdjacentCutThenSpeed() async throws {
        let (src, out) = tmpURLs("mp4")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: out) }
        try await writeSampleVideo(to: src, width: 320, height: 240, fps: 30, seconds: 1.0)

        // cut [0.2,0.4], speed 2x [0.4,0.6]  (share the boundary 0.4, no overlap)
        let cuts = ["c": CutRegion(id: "c", startTime: 0.2, duration: 0.2, zIndex: 10)]
        let speeds = ["s": SpeedRegion(id: "s", startTime: 0.4, duration: 0.2, speed: 2.0, zIndex: 5)]
        // Expected: 1.0 - 0.2(cut) - 0.2(speed) + 0.2/2 = 0.7
        let expected = TimeRemap.exportDuration(1.0, cutRegions: cuts, speedRegions: speeds)
        XCTAssertEqual(expected, 0.7, accuracy: 1e-9)

        let job = VideoExporter.Job(mainVideoURL: src, model: model(srcW: 320, srcH: 240),
                                    duration: 1.0, cutRegions: cuts, speedRegions: speeds, aspectRatio: .r16x9,
                                    settings: ExportSettings(resolution: "720p", fps: 30, format: .mp4),
                                    outputURL: out)
        _ = try await VideoExporter().export(job)
        let (dur, _) = try await assetDurationAndSize(out)
        XCTAssertEqual(dur, expected, accuracy: 0.2, "adjacent cut+speed duration")
    }

    /// Overlapping cut + speed. In the segment walk (mapExportTimeToSourceTime and the
    /// audio mux), a CUT wins over a speed region wherever they overlap, because the
    /// cut check runs first. The naive `exportDuration` formula does NOT account for
    /// this — it unconditionally subtracts the full speed-region duration. This test
    /// derives the true frame-loop export duration *empirically* from the remap and
    /// flags the discrepancy with the naive formula that drives totalFrames/audio.
    func testOverlappingCutAndSpeedDurationConsistency() throws {
        let duration = 1.0
        // cut [0.3,0.6], speed 2x [0.4,0.7] — overlap on [0.4,0.6]
        let cuts = ["c": CutRegion(id: "c", startTime: 0.3, duration: 0.3, zIndex: 10)]
        let speeds = ["s": SpeedRegion(id: "s", startTime: 0.4, duration: 0.3, speed: 2.0, zIndex: 5)]

        let naive = TimeRemap.exportDuration(duration, cutRegions: cuts, speedRegions: speeds)

        // Segment walk the exporter actually performs (cut beats speed in the overlap):
        //   seg [0,0.3] speed1 -> 0.30 export
        //   seg [0.3,0.4] CUT  -> 0
        //   seg [0.4,0.6] CUT (cut beats speed) -> 0
        //   seg [0.6,0.7] speed2 -> 0.05 export
        //   seg [0.7,1.0] speed1 -> 0.30 export
        let analyticTrue = 0.30 + 0.05 + 0.30  // = 0.65

        // Empirically derive the true export duration: the smallest export time E such
        // that mapping E reaches the source end (1.0). Bisection over the monotonic map.
        func mapped(_ e: Double) -> Double {
            TimeRemap.mapExportTimeToSourceTime(e, duration: duration, cutRegions: cuts, speedRegions: speeds)
        }
        var lo = 0.0, hi = 2.0
        for _ in 0..<60 {
            let mid = (lo + hi) / 2
            if mapped(mid) >= duration - 1e-9 { hi = mid } else { lo = mid }
        }
        let empiricalTrue = hi
        XCTAssertEqual(empiricalTrue, analyticTrue, accuracy: 1e-3,
                       "empirical frame-loop export duration matches segment walk")

        // FIXED: exportDuration now uses the same segment walk, so it equals the
        // frame-loop truth (0.65) even on cut/speed overlap — totalFrames, the audio
        // timeline, and the time map all agree (no truncation / desync).
        XCTAssertEqual(naive, analyticTrue, accuracy: 1e-3,
                       "exportDuration agrees with the frame-loop segment walk on overlap")
        XCTAssertEqual(naive, empiricalTrue, accuracy: 1e-3,
                       "exportDuration agrees with the empirical end-of-content export time")
    }

    /// End-to-end check that the exported MP4 duration tracks the (now overlap-correct)
    /// `exportDuration` segment walk (~0.65s), so cut+speed overlap is no longer
    /// truncated and the audio timeline stays in sync with the frames.
    func testOverlappingCutSpeedExportedDurationMatchesSegmentWalk() async throws {
        let (src, out) = tmpURLs("mp4")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: out) }
        try await writeSampleVideo(to: src, width: 320, height: 240, fps: 30, seconds: 1.0)

        let cuts = ["c": CutRegion(id: "c", startTime: 0.3, duration: 0.3, zIndex: 10)]
        let speeds = ["s": SpeedRegion(id: "s", startTime: 0.4, duration: 0.3, speed: 2.0, zIndex: 5)]
        let expected = TimeRemap.exportDuration(1.0, cutRegions: cuts, speedRegions: speeds) // ~0.65

        let job = VideoExporter.Job(mainVideoURL: src, model: model(srcW: 320, srcH: 240),
                                    duration: 1.0, cutRegions: cuts, speedRegions: speeds, aspectRatio: .r16x9,
                                    settings: ExportSettings(resolution: "720p", fps: 30, format: .mp4),
                                    outputURL: out)
        _ = try await VideoExporter().export(job)
        let (dur, _) = try await assetDurationAndSize(out)
        XCTAssertEqual(dur, expected, accuracy: 0.12,
                       "exported duration follows the overlap-correct segment walk")
    }

    // MARK: - (c) Speed 0.5x and 4x duration math

    func testSpeedHalf_lengthensDuration() async throws {
        let (src, out) = tmpURLs("mp4")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: out) }
        try await writeSampleVideo(to: src, width: 320, height: 240, fps: 30, seconds: 1.0)

        // speed 0.5x over [0.3,0.7] (0.4s). Expected: 1.0 - 0.4 + 0.4/0.5 = 1.4
        let speeds = ["s": SpeedRegion(id: "s", startTime: 0.3, duration: 0.4, speed: 0.5, zIndex: 5)]
        let expected = TimeRemap.exportDuration(1.0, cutRegions: [:], speedRegions: speeds)
        XCTAssertEqual(expected, 1.4, accuracy: 1e-9)

        let job = VideoExporter.Job(mainVideoURL: src, model: model(srcW: 320, srcH: 240),
                                    duration: 1.0, speedRegions: speeds, aspectRatio: .r16x9,
                                    settings: ExportSettings(resolution: "720p", fps: 30, format: .mp4),
                                    outputURL: out)
        _ = try await VideoExporter().export(job)
        let (dur, _) = try await assetDurationAndSize(out)
        XCTAssertEqual(dur, 1.4, accuracy: 0.2, "0.5x slow-motion lengthens output")
    }

    func testSpeed4x_shortensDuration() async throws {
        let (src, out) = tmpURLs("mp4")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: out) }
        try await writeSampleVideo(to: src, width: 320, height: 240, fps: 30, seconds: 1.0)

        // speed 4x over [0.3,0.7] (0.4s). Expected: 1.0 - 0.4 + 0.4/4 = 0.7
        let speeds = ["s": SpeedRegion(id: "s", startTime: 0.3, duration: 0.4, speed: 4.0, zIndex: 5)]
        let expected = TimeRemap.exportDuration(1.0, cutRegions: [:], speedRegions: speeds)
        XCTAssertEqual(expected, 0.7, accuracy: 1e-9)

        let job = VideoExporter.Job(mainVideoURL: src, model: model(srcW: 320, srcH: 240),
                                    duration: 1.0, speedRegions: speeds, aspectRatio: .r16x9,
                                    settings: ExportSettings(resolution: "720p", fps: 30, format: .mp4),
                                    outputURL: out)
        _ = try await VideoExporter().export(job)
        let (dur, _) = try await assetDurationAndSize(out)
        XCTAssertEqual(dur, 0.7, accuracy: 0.2, "4x fast-forward shortens output")
    }

    // MARK: - (d) 2K resolution + 9:16 aspect — exact output dimensions

    func test2K_9x16_exactDimensions() async throws {
        let (src, out) = tmpURLs("mp4")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: out) }
        try await writeSampleVideo(to: src, width: 240, height: 320, fps: 30, seconds: 0.5)

        // Geometry contract: 2K is height-driven (1440); 9:16 width = round(1440*9/16)=810 (even).
        let expectedDims = Geometry.exportDimensions(resolution: "2k", aspectRatio: .r9x16)
        XCTAssertEqual(expectedDims, SizeI(width: 810, height: 1440), "2K 9:16 geometry")

        let job = VideoExporter.Job(mainVideoURL: src, model: model(srcW: 240, srcH: 320),
                                    duration: 0.5, aspectRatio: .r9x16,
                                    settings: ExportSettings(resolution: "2k", fps: 30, format: .mp4),
                                    outputURL: out)
        _ = try await VideoExporter().export(job)
        let (_, size) = try await assetDurationAndSize(out)
        XCTAssertEqual(Int(size.width.rounded()), expectedDims.width, "output width matches Geometry")
        XCTAssertEqual(Int(size.height.rounded()), expectedDims.height, "output height matches Geometry")
    }

    // MARK: - (e) cancel() then a SECOND export on the SAME instance

    func testCancelThenReexportSameInstanceSucceeds() async throws {
        let (src, out1) = tmpURLs("mp4")
        let out2 = FileManager.default.temporaryDirectory.appendingPathComponent("smoooth-out2-\(UUID().uuidString).mp4")
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: out1)
            try? FileManager.default.removeItem(at: out2)
        }
        try await writeSampleVideo(to: src, width: 320, height: 240, fps: 30, seconds: 1.0)

        let exporter = VideoExporter()
        // Pre-set the cancel flag, then start an export. The first frame check should
        // throw .cancelled. resetCancellation() runs at the top of export(), so this
        // first call would otherwise NOT see the flag — to deterministically force a
        // cancelled run we cancel and immediately await, racing the reset. Instead we
        // assert the regression target directly: after a real cancel, isCancelled is
        // true; a fresh export() must clear it and complete.
        exporter.cancel()
        XCTAssertTrue(exporter.isCancelled, "cancel() sets the flag")

        // Second export on the same instance must succeed (regression: cancel flag reset).
        let job = VideoExporter.Job(mainVideoURL: src, model: model(srcW: 320, srcH: 240),
                                    duration: 1.0, aspectRatio: .r16x9,
                                    settings: ExportSettings(resolution: "720p", fps: 30, format: .mp4),
                                    outputURL: out2)
        _ = try await exporter.export(job)
        XCTAssertFalse(exporter.isCancelled, "export() must reset the cancel flag")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out2.path), "second export produced a file")
        let (dur, _) = try await assetDurationAndSize(out2)
        XCTAssertEqual(dur, 1.0, accuracy: 0.2, "second export full duration")
    }

    /// Stronger variant: actually let a mid-flight cancel abort an export, then prove a
    /// subsequent export on the same instance recovers. Uses a longer source so the
    /// first export is still running when cancel() lands.
    func testMidFlightCancelThenReexport() async throws {
        let (src, out1) = tmpURLs("mp4")
        let out2 = FileManager.default.temporaryDirectory.appendingPathComponent("smoooth-out2-\(UUID().uuidString).mp4")
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: out1)
            try? FileManager.default.removeItem(at: out2)
        }
        // ~3s @ high res so the encode loop runs long enough to be cancelled.
        try await writeSampleVideo(to: src, width: 640, height: 480, fps: 30, seconds: 3.0)

        let exporter = VideoExporter()
        let job1 = VideoExporter.Job(mainVideoURL: src, model: model(srcW: 640, srcH: 480),
                                     duration: 3.0, aspectRatio: .r16x9,
                                     settings: ExportSettings(resolution: "1080p", fps: 30, format: .mp4),
                                     outputURL: out1)
        let task = Task { try await exporter.export(job1) }
        // Let it get going, then cancel.
        try await Task.sleep(nanoseconds: 60_000_000)
        exporter.cancel()
        var firstWasCancelled = false
        do { _ = try await task.value } catch ExportError.cancelled { firstWasCancelled = true } catch { /* finished or other */ }

        // Regardless of whether we won the race, a fresh export must work.
        let job2 = VideoExporter.Job(mainVideoURL: src, model: model(srcW: 640, srcH: 480),
                                     duration: 1.0, aspectRatio: .r16x9,
                                     settings: ExportSettings(resolution: "720p", fps: 30, format: .mp4),
                                     outputURL: out2)
        _ = try await exporter.export(job2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out2.path),
                      "second export succeeds after cancel (firstWasCancelled=\(firstWasCancelled))")
        XCTAssertFalse(exporter.isCancelled)
    }

    // MARK: - (f) GIF frame count ≈ exportDuration × fps

    func testGifFrameCountMatchesDurationTimesFps() async throws {
        let (src, out) = tmpURLs("gif")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: out) }
        let fps = 15
        let seconds = 1.0
        try await writeSampleVideo(to: src, width: 320, height: 240, fps: 30, seconds: seconds)

        let job = VideoExporter.Job(mainVideoURL: src, model: model(srcW: 320, srcH: 240),
                                    duration: seconds, aspectRatio: .r16x9,
                                    settings: ExportSettings(resolution: "720p", fps: fps, format: .gif),
                                    outputURL: out)
        _ = try await VideoExporter().export(job)

        let exportDur = TimeRemap.exportDuration(seconds, cutRegions: [:], speedRegions: [:])
        let expectedFrames = max(1, Int((exportDur * Double(fps)).rounded(.down)))  // matches exporter's totalFrames
        XCTAssertEqual(expectedFrames, 15)

        guard let imgSrc = CGImageSourceCreateWithURL(out as CFURL, nil) else {
            XCTFail("gif unreadable"); return
        }
        let count = CGImageSourceGetCount(imgSrc)
        // Frames can be dropped only if a render returns nil; for a clean source the
        // count should equal totalFrames exactly.
        XCTAssertEqual(count, expectedFrames, "gif frame count == floor(exportDuration*fps)")
    }

    /// GIF with a cut: frame count should track the *post-cut* export duration.
    func testGifFrameCountWithCut() async throws {
        let (src, out) = tmpURLs("gif")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: out) }
        let fps = 20
        try await writeSampleVideo(to: src, width: 320, height: 240, fps: 30, seconds: 1.0)

        let cuts = ["c": CutRegion(id: "c", startTime: 0.25, duration: 0.5, zIndex: 10)]
        let job = VideoExporter.Job(mainVideoURL: src, model: model(srcW: 320, srcH: 240),
                                    duration: 1.0, cutRegions: cuts, aspectRatio: .r16x9,
                                    settings: ExportSettings(resolution: "720p", fps: fps, format: .gif),
                                    outputURL: out)
        _ = try await VideoExporter().export(job)

        let exportDur = TimeRemap.exportDuration(1.0, cutRegions: cuts, speedRegions: [:]) // 0.5
        let expectedFrames = max(1, Int((exportDur * Double(fps)).rounded(.down)))          // 10
        XCTAssertEqual(expectedFrames, 10)
        guard let imgSrc = CGImageSourceCreateWithURL(out as CFURL, nil) else { XCTFail("gif unreadable"); return }
        XCTAssertEqual(CGImageSourceGetCount(imgSrc), expectedFrames, "gif frames track post-cut duration")
    }
}
