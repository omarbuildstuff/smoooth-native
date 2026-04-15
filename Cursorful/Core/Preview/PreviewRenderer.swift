import AVFoundation
import Combine
import CoreMedia
import Foundation
import Metal
import MetalKit

/// Drives preview rendering: on each MTKView draw, pulls a frame from FrameProvider, runs effects,
/// and presents. Supports pause/play and scrubbing to a time.
@MainActor
final class PreviewRenderer: NSObject, ObservableObject, MTKViewDelegate {

    private let provider: FrameProvider
    let context: EffectContext
    private let renderer: MetalRenderer
    private let graph: EffectGraph

    /// Current frame pixel buffer cache (so we can re-render on redraw without decoding again).
    private var latestPixelBuffer: CVPixelBuffer?

    /// Current timeline time.
    @Published private(set) var currentTime: CMTime = .zero
    @Published var isPlaying: Bool = false

    var sourceSize: CGSize = .zero
    var onTick: ((CMTime) -> Void)?

    /// The zoom effect reference so the caller can update the zoom sample per frame.
    let zoomEffect = ZoomEffect()
    let cursorEffect = CursorOverlayEffect()
    let rippleEffect = ClickRippleEffect()
    let mockupEffect = MockupFrameEffect()

    /// Current list of zoom regions driving the zoom effect per-frame.
    var zoomRegions: [ZoomRegion] = []
    var renderMockup: Bool = true
    var renderCursor: Bool = true
    var renderRipples: Bool = true

    // Playback
    private var playStartWallclock: TimeInterval = 0
    private var playStartMediaSec: Double = 0
    private var playbackTimer: Timer?

    init(provider: FrameProvider, context: EffectContext) throws {
        self.provider = provider
        self.context = context
        self.renderer = MetalRenderer(context: context)
        self.graph = EffectGraph(context: context)
        super.init()

        try rebuildEffects()
    }

    func rebuildEffects() throws {
        var effects: [Effect] = [zoomEffect]
        if renderCursor  { effects.append(cursorEffect) }
        if renderRipples { effects.append(rippleEffect) }
        if renderMockup  { effects.append(mockupEffect) }
        try graph.setEffects(effects)
    }

    // MARK: - Transport

    func seek(to t: CMTime) async {
        currentTime = t
        do {
            latestPixelBuffer = try await provider.frame(at: t)
        } catch {
            Log.render.error("Seek failed: \(error.localizedDescription)")
        }
        onTick?(t)
    }

    func play() {
        guard !isPlaying else { return }
        isPlaying = true
        playStartWallclock = CACurrentMediaTime()
        playStartMediaSec = currentTime.secondsOrZero
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.advance() }
        }
    }

    func pause() {
        isPlaying = false
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    private func advance() async {
        let elapsed = CACurrentMediaTime() - playStartWallclock
        let target = CMTime(seconds: playStartMediaSec + elapsed, preferredTimescale: 1_000_000_000)
        do {
            if let pb = try await provider.frame(at: target) {
                latestPixelBuffer = pb
            }
        } catch {
            Log.render.error("Playback frame error: \(error.localizedDescription)")
        }
        currentTime = target
        onTick?(target)
    }

    // MARK: - MTKViewDelegate

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        Task { @MainActor in self.drawNow(in: view) }
    }

    @MainActor
    private func drawNow(in view: MTKView) {
        guard let pb = latestPixelBuffer,
              let input = context.textureCache.texture(from: pb),
              let drawable = view.currentDrawable,
              let cb = context.queue.makeCommandBuffer() else {
            view.currentDrawable?.present()
            return
        }
        // Update per-frame uniforms from timeline state
        let t = currentTime
        zoomEffect.sample = AutoZoomPlanner.evaluate(regions: zoomRegions, at: t)

        let viewportSize = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        let output = drawable.texture
        graph.render(input: input, output: output, time: t, commandBuffer: cb, viewport: viewportSize)
        cb.present(drawable)
        cb.commit()
    }
}
