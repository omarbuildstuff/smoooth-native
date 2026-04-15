import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import MetalKit

/// Pumps frames from the source video through the EffectGraph at export resolution and hands each
/// rendered pixel buffer to the `VideoEncoder`.
///
/// Post-review fixes:
/// - Render target is a **CVPixelBuffer-backed** MTLTexture (`.shared` storage via
///   `CVMetalTextureCache`). No CPU readback, no `getBytes`, no `.private` texture.
/// - No `commandBuffer.waitUntilCompleted()` — we rely on the encoder's
///   `isReadyForMoreMediaData` gate for backpressure, and on Metal's internal resource tracking
///   to ensure the pixel buffer is GPU-fresh before append.
/// - Lives outside `MainActor`; UI mirrors `@Published progress/state` on MainActor via the
///   ExporterHolder in ExportSheet.
final class Exporter: ObservableObject, @unchecked Sendable {

    @Published var progress: Double = 0
    @Published var state: State = .idle

    enum State: Equatable { case idle, running, finished(URL), failed(String) }

    let package: RecordingPackage
    let project: Project
    let preset: ExportPreset
    let outputURL: URL

    init(package: RecordingPackage, project: Project, preset: ExportPreset, outputURL: URL? = nil) {
        self.package = package
        self.project = project
        self.preset = preset
        self.outputURL = outputURL ?? RecordingStore.rootURL
            .appendingPathComponent("\(package.id.uuidString).mp4")
    }

    func run() async {
        await MainActor.run { self.state = .running; self.progress = 0 }
        do {
            let ctx = try EffectContext()

            let provider = FrameProvider(url: package.videoURL)
            try await provider.prepare()
            let sourceSize = await provider.naturalSize
            let duration   = await provider.duration
            try await provider.startLinearRead(from: .zero, to: duration)

            let encoder = VideoEncoder(url: outputURL, preset: preset)
            try encoder.prepare()

            // Build effect graph with project settings
            let graph = EffectGraph(context: ctx)
            let zoom   = ZoomEffect()
            let cursor = CursorOverlayEffect()
            let ripple = ClickRippleEffect()
            let mockup = MockupFrameEffect()
            let events = EventLogReader.read(url: package.eventsURL)
            cursor.sourceSize = sourceSize
            ripple.sourceSize = sourceSize
            cursor.size = project.cursor.size
            mockup.settings.paddingRatio   = project.mockup.paddingRatio
            mockup.settings.cornerRadius   = project.mockup.cornerRadius
            mockup.settings.shadowStrength = project.mockup.shadowStrength
            mockup.settings.shadowSpread   = project.mockup.shadowSpread
            cursor.load(samples: events.cursorSamples)
            ripple.load(clicks: events.clicks)

            var effects: [Effect] = [zoom]
            if project.cursor.enabled    { effects.append(cursor) }
            if project.cursor.showRipples { effects.append(ripple) }
            if project.mockup.enabled    { effects.append(mockup) }
            try graph.setEffects(effects)

            // Start encoder session at 0 — source video is already session-rebased by ScratchWriter.
            try encoder.start(atSource: .zero)

            let w = preset.width, h = preset.height
            let fps = preset.fps
            let totalFrames = Int(duration.secondsOrZero * Double(fps))
            var frameIndex: Int = 0

            guard let pool = encoder.pixelBufferPool() else {
                throw ExportError.noPixelBufferPool
            }

            while let sourcePB = await provider.nextFrame() {
                guard let input = ctx.textureCache.texture(from: sourcePB) else { continue }

                // Get a fresh destination PixelBuffer from the encoder's pool and wrap as MTLTexture.
                var outPB: CVPixelBuffer?
                let s = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outPB)
                guard s == kCVReturnSuccess, let destPB = outPB,
                      let destTex = ctx.textureCache.texture(from: destPB) else {
                    Log.export.warning("Failed to borrow destination pixel buffer")
                    continue
                }

                let t = CMTime(value: CMTimeValue(frameIndex), timescale: fps)
                zoom.sample = AutoZoomPlanner.evaluate(regions: project.zoomTrack, at: t)

                guard let cb = ctx.queue.makeCommandBuffer() else { continue }
                graph.render(input: input,
                             output: destTex,
                             time: t,
                             commandBuffer: cb,
                             viewport: CGSize(width: w, height: h))
                cb.commit()
                // No waitUntilCompleted. VideoEncoder's append awaits isReadyForMoreMediaData;
                // the adaptor guarantees GPU work completes before consuming the pixel buffer.

                try await encoder.append(pixelBuffer: destPB, pts: t)

                frameIndex += 1
                if totalFrames > 0 {
                    let frac = Double(frameIndex) / Double(totalFrames)
                    await MainActor.run { self.progress = min(1, frac) }
                }
            }

            try await encoder.finish()
            await MainActor.run {
                self.state = .finished(self.outputURL)
                self.progress = 1
            }
            Log.export.info("Export finished: \(self.outputURL.path)")
        } catch {
            Log.export.error("Export failed: \(error.localizedDescription)")
            await MainActor.run { self.state = .failed(error.localizedDescription) }
        }
    }

    enum ExportError: Error, LocalizedError {
        case noPixelBufferPool
        var errorDescription: String? {
            switch self {
            case .noPixelBufferPool: return "Encoder did not provide a pixel buffer pool."
            }
        }
    }
}
