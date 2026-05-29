import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Seek-driven exporter: reproduces the renderer's frame loop (export time →
/// remapped source time → composite → encode). Writes H.264 MP4 via AVAssetWriter
/// (VideoToolbox hardware on Apple Silicon) or an animated GIF via ImageIO.
///
/// NOTE: audio remapping (cut/speed-aware) is wired in during integration with the
/// capture engine; this stage produces the fully-composited video track.
public final class VideoExporter: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    public init() {}

    public func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    private func resetCancellation() { lock.lock(); _cancelled = false; lock.unlock() }

    public struct Job: Sendable {
        public var mainVideoURL: URL
        public var webcamVideoURL: URL?
        public var model: SceneModel
        public var backgroundImage: CGImage?
        public var cursorBitmaps: [String: CursorBitmap]
        public var customCursor: CursorBitmap?
        public var duration: Double
        public var cutRegions: [String: CutRegion]
        public var speedRegions: [String: SpeedRegion]
        public var aspectRatio: AspectRatio
        public var settings: ExportSettings
        public var outputURL: URL

        public init(mainVideoURL: URL, webcamVideoURL: URL? = nil, model: SceneModel,
                    backgroundImage: CGImage? = nil, cursorBitmaps: [String: CursorBitmap] = [:],
                    customCursor: CursorBitmap? = nil,
                    duration: Double, cutRegions: [String: CutRegion] = [:],
                    speedRegions: [String: SpeedRegion] = [:], aspectRatio: AspectRatio,
                    settings: ExportSettings, outputURL: URL) {
            self.mainVideoURL = mainVideoURL; self.webcamVideoURL = webcamVideoURL; self.model = model
            self.backgroundImage = backgroundImage; self.cursorBitmaps = cursorBitmaps
            self.customCursor = customCursor
            self.duration = duration; self.cutRegions = cutRegions; self.speedRegions = speedRegions
            self.aspectRatio = aspectRatio; self.settings = settings; self.outputURL = outputURL
        }
    }

    public func export(_ job: Job, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        resetCancellation() // allow re-use after a prior cancel
        let dims = Geometry.exportDimensions(resolution: job.settings.resolution, aspectRatio: job.aspectRatio)
        let exportDur = TimeRemap.exportDuration(job.duration, cutRegions: job.cutRegions, speedRegions: job.speedRegions)
        let fps = max(1, job.settings.fps)
        let totalFrames = max(1, Int((exportDur * Double(fps)).rounded(.down)))

        let mainSource = FrameSource(url: job.mainVideoURL)
        let webcamSource = job.webcamVideoURL.map { FrameSource(url: $0) }

        // Renders the composited frame for export-frame `index`.
        var lastImage: CGImage?
        func renderFrame(_ index: Int) async -> CGImage? {
            let exportTime = Double(index) / Double(fps)
            let sourceTime = TimeRemap.mapExportTimeToSourceTime(exportTime, duration: job.duration,
                                                                 cutRegions: job.cutRegions, speedRegions: job.speedRegions)
            guard let main = await mainSource.image(at: sourceTime) ?? lastImage else { return nil }
            lastImage = main
            let webcam = webcamSource != nil ? await webcamSource!.image(at: sourceTime) : nil
            let inputs = SceneFrameInputs(mainVideo: main, webcamVideo: webcam,
                                          backgroundImage: job.backgroundImage, cursorBitmaps: job.cursorBitmaps,
                                          customCursor: job.customCursor)
            return SceneRenderer.renderImage(model: job.model, inputs: inputs, currentTime: sourceTime, outputSize: dims)
        }

        if FileManager.default.fileExists(atPath: job.outputURL.path) {
            try? FileManager.default.removeItem(at: job.outputURL)
        }

        if job.settings.format == .gif {
            try await exportGIF(renderFrame: renderFrame, totalFrames: totalFrames, fps: fps,
                                outputURL: job.outputURL, progress: progress)
            return job.outputURL
        }

        // Video first (to a temp file), then best-effort mux remapped source audio.
        let tempVideo = job.outputURL.deletingPathExtension().appendingPathExtension("video.mp4")
        try? FileManager.default.removeItem(at: tempVideo)
        try await exportMP4(renderFrame: renderFrame, totalFrames: totalFrames, fps: fps,
                            dims: dims, outputURL: tempVideo, progress: progress)

        if await mainSource.hasAudio() {
            do {
                try await muxAudio(videoOnly: tempVideo, sourceVideo: job.mainVideoURL,
                                   duration: job.duration, cutRegions: job.cutRegions,
                                   speedRegions: job.speedRegions, output: job.outputURL)
                try? FileManager.default.removeItem(at: tempVideo)
            } catch {
                // Audio mux failed — keep the (valid) video-only output.
                try? FileManager.default.removeItem(at: job.outputURL)
                try FileManager.default.moveItem(at: tempVideo, to: job.outputURL)
            }
        } else {
            try? FileManager.default.removeItem(at: job.outputURL)
            try FileManager.default.moveItem(at: tempVideo, to: job.outputURL)
        }
        return job.outputURL
    }

    // MARK: - Audio mux (cut/speed-aware)

    private func muxAudio(videoOnly: URL, sourceVideo: URL, duration: Double,
                          cutRegions: [String: CutRegion], speedRegions: [String: SpeedRegion],
                          output: URL) async throws {
        let comp = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoOnly)
        guard let vTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let compV = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.writeFailed("audio mux: video track")
        }
        let vDur = try await videoAsset.load(.duration)
        try compV.insertTimeRange(CMTimeRange(start: .zero, duration: vDur), of: vTrack, at: .zero)

        let srcAsset = AVURLAsset(url: sourceVideo)
        let hasSpeed = !speedRegions.isEmpty
        if let aTrack = try await srcAsset.loadTracks(withMediaType: .audio).first,
           let compA = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            // Same segment walk as TimeRemap: drop cuts, scale speed regions.
            let cuts = Array(cutRegions.values), speeds = Array(speedRegions.values)
            var events = Set<Double>([0, duration])
            for r in cuts { events.insert(r.startTime); events.insert(r.startTime + r.duration) }
            for r in speeds { events.insert(r.startTime); events.insert(r.startTime + r.duration) }
            let sorted = events.sorted().filter { $0 >= 0 && $0 <= duration }
            var cursor = CMTime.zero
            for i in 0..<max(0, sorted.count - 1) {
                let segStart = sorted[i], segEnd = sorted[i + 1]
                let mid = segStart + (segEnd - segStart) / 2
                if cuts.contains(where: { mid >= $0.startTime && mid < $0.startTime + $0.duration }) { continue }
                let speed = speeds.first(where: { mid >= $0.startTime && mid < $0.startTime + $0.duration })?.speed ?? 1
                let range = CMTimeRange(start: CMTime(seconds: segStart, preferredTimescale: 600),
                                        duration: CMTime(seconds: segEnd - segStart, preferredTimescale: 600))
                try compA.insertTimeRange(range, of: aTrack, at: cursor)
                if speed != 1 {
                    let scaledDur = CMTime(seconds: (segEnd - segStart) / speed, preferredTimescale: 600)
                    compA.scaleTimeRange(CMTimeRange(start: cursor, duration: range.duration), toDuration: scaledDur)
                    cursor = cursor + scaledDur
                } else {
                    cursor = cursor + range.duration
                }
            }
        }

        let preset = hasSpeed ? AVAssetExportPresetHighestQuality : AVAssetExportPresetPassthrough
        guard let session = AVAssetExportSession(asset: comp, presetName: preset) else {
            throw ExportError.writeFailed("audio mux: export session")
        }
        try? FileManager.default.removeItem(at: output)
        session.outputURL = output
        session.outputFileType = .mp4
        await session.export()
        if session.status != .completed {
            throw ExportError.writeFailed("audio mux: \(session.error?.localizedDescription ?? "export failed")")
        }
    }

    // MARK: - MP4

    private func exportMP4(renderFrame: (Int) async -> CGImage?, totalFrames: Int, fps: Int,
                           dims: SizeI, outputURL: URL, progress: (@Sendable (Double) -> Void)?) async throws {
        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else {
            throw ExportError.writerSetupFailed
        }
        // High quality, approximating the original libx264 crf 15 / tune animation.
        let bitrate = Int(Double(dims.width * dims.height) * Double(fps) * 0.25)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: dims.width,
            AVVideoHeightKey: dims.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoAllowFrameReorderingKey: true,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: dims.width,
                kCVPixelBufferHeightKey as String: dims.height,
            ])
        guard writer.canAdd(input) else { throw ExportError.writerSetupFailed }
        writer.add(input)
        guard writer.startWriting() else { throw ExportError.writeFailed(writer.error?.localizedDescription ?? "startWriting") }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<totalFrames {
            if isCancelled { writer.cancelWriting(); throw ExportError.cancelled }
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 3_000_000)
            }
            guard let cg = await renderFrame(frame) else { continue }
            guard let pool = adaptor.pixelBufferPool,
                  let pb = Self.makePixelBuffer(from: cg, pool: pool) else {
                throw ExportError.pixelBufferPoolUnavailable
            }
            let pts = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
            if !adaptor.append(pb, withPresentationTime: pts) {
                throw ExportError.writeFailed(writer.error?.localizedDescription ?? "append frame \(frame)")
            }
            progress?(Double(frame + 1) / Double(totalFrames))
        }

        input.markAsFinished()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }
        if writer.status != .completed {
            throw ExportError.writeFailed(writer.error?.localizedDescription ?? "writer status \(writer.status.rawValue)")
        }
    }

    // MARK: - GIF

    private func exportGIF(renderFrame: (Int) async -> CGImage?, totalFrames: Int, fps: Int,
                           outputURL: URL, progress: (@Sendable (Double) -> Void)?) async throws {
        guard let dest = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.gif.identifier as CFString, totalFrames, nil) else {
            throw ExportError.writerSetupFailed
        }
        let gifProps = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]]
        CGImageDestinationSetProperties(dest, gifProps as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: 1.0 / Double(fps)]]
        for frame in 0..<totalFrames {
            if isCancelled { throw ExportError.cancelled }
            guard let cg = await renderFrame(frame) else { continue }
            CGImageDestinationAddImage(dest, cg, frameProps as CFDictionary)
            progress?(Double(frame + 1) / Double(totalFrames))
        }
        if !CGImageDestinationFinalize(dest) {
            throw ExportError.writeFailed("GIF finalize failed")
        }
    }

    // MARK: - Helpers

    static func makePixelBuffer(from image: CGImage, pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var pbOut: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut) == kCVReturnSuccess, let pb = pbOut else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb),
                                  width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb),
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return nil
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb)))
        return pb
    }
}
