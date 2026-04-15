import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import MetalKit

/// Pumps frames from the source video through the EffectGraph at export resolution and hands each
/// rendered pixel buffer to the `VideoEncoder`.
///
/// Lifecycle:
///   let exporter = Exporter(package: pkg, project: project, preset: preset)
///   try await exporter.run(progress: { p in ... })
///   → produces `output.mp4` next to the bundle
@MainActor
final class Exporter: ObservableObject {

    @Published var progress: Double = 0
    @Published var state: State = .idle

    enum State: Equatable { case idle, running, finished(URL), failed(String) }

    let package: RecordingPackage
    let project: Project
    let preset: ExportPreset
    let outputURL: URL

    private var ctx: EffectContext?
    private var provider: FrameProvider?
    private var encoder: VideoEncoder?

    init(package: RecordingPackage, project: Project, preset: ExportPreset, outputURL: URL? = nil) {
        self.package = package
        self.project = project
        self.preset = preset
        self.outputURL = outputURL ?? RecordingStore.rootURL
            .appendingPathComponent("\(package.id.uuidString).mp4")
    }

    func run() async {
        state = .running
        progress = 0
        do {
            let ctx = try EffectContext()
            self.ctx = ctx
            let provider = FrameProvider(url: package.videoURL)
            try await provider.prepare()
            self.provider = provider

            let encoder = VideoEncoder(url: outputURL, preset: preset)
            try encoder.prepare()
            self.encoder = encoder

            let sourceSize = await provider.naturalSize
            let duration   = await provider.duration
            try await provider.startLinearRead(from: .zero, to: duration)

            // Build effect graph for export quality
            let graph = EffectGraph(context: ctx)
            let zoom = ZoomEffect()
            let cursor = CursorOverlayEffect()
            let ripple = ClickRippleEffect()
            let mockup = MockupFrameEffect()
            let events = EventLogReader.read(url: package.eventsURL)
            cursor.sourceSize = sourceSize
            ripple.sourceSize = sourceSize
            cursor.size = project.cursor.size
            mockup.settings.paddingRatio = project.mockup.paddingRatio
            mockup.settings.cornerRadius = project.mockup.cornerRadius
            mockup.settings.shadowStrength = project.mockup.shadowStrength
            mockup.settings.shadowSpread = project.mockup.shadowSpread
            cursor.load(samples: events.cursorSamples)
            ripple.load(clicks: events.clicks)

            var effects: [Effect] = [zoom]
            if project.cursor.enabled  { effects.append(cursor) }
            if project.cursor.showRipples { effects.append(ripple) }
            if project.mockup.enabled  { effects.append(mockup) }
            try graph.setEffects(effects)

            // Start encoder session
            try encoder.start(atSource: .zero)

            // Output texture (destination) sized to preset
            let w = preset.width, h = preset.height
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                width: w, height: h, mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .private

            // Frame-by-frame pump
            let fps = preset.fps
            var frameIndex: Int = 0
            let totalFrames = Int(duration.secondsOrZero * Double(fps))

            while let pb = await provider.nextFrame() {
                guard let input = ctx.textureCache.texture(from: pb) else { continue }
                guard let output = ctx.device.makeTexture(descriptor: desc) else { continue }

                // Time for this frame
                let t = CMTime(value: CMTimeValue(frameIndex), timescale: fps)
                zoom.sample = AutoZoomPlanner.evaluate(regions: project.zoomTrack, at: t)

                let cb = ctx.queue.makeCommandBuffer()!
                graph.render(input: input,
                             output: output,
                             time: t,
                             commandBuffer: cb,
                             viewport: CGSize(width: w, height: h))
                cb.commit()
                cb.waitUntilCompleted()

                // Copy output texture into a pixel buffer the encoder can ingest.
                guard let dstPB = try await makePixelBuffer(from: output, pool: encoder.pixelBufferPool()) else {
                    continue
                }
                try await encoder.append(pixelBuffer: dstPB, pts: t)

                frameIndex += 1
                if totalFrames > 0 {
                    let frac = Double(frameIndex) / Double(totalFrames)
                    self.progress = min(1, frac)
                }
            }

            try await encoder.finish()
            state = .finished(outputURL)
            progress = 1
            Log.export.info("Export finished: \(self.outputURL.path)")
        } catch {
            Log.export.error("Export failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    /// Read back a Metal texture into a CVPixelBuffer from the encoder's pool.
    private func makePixelBuffer(from texture: MTLTexture,
                                 pool: CVPixelBufferPool?) async throws -> CVPixelBuffer? {
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
        guard status == kCVReturnSuccess, let pb else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }

        let region = MTLRegionMake2D(0, 0, texture.width, texture.height)
        texture.getBytes(base, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)
        return pb
    }
}
