import CoreGraphics
import CoreMedia
import Foundation
import Metal

/// Draws an enlarged arrow cursor at the smoothed position.
///
/// Call `set(samples:)` with the raw cursor log. Each encode samples + smooths in one step.
final class CursorOverlayEffect: Effect {
    let name = "CursorOverlay"

    /// Size of the cursor (UV-space half-height as fraction of viewport's short edge).
    var size: CGFloat = 0.022
    /// Fill color (RGB, 0..1).
    var fill: SIMD3<Float> = [1.0, 1.0, 1.0]
    /// Outline color.
    var stroke: SIMD3<Float> = [0.0, 0.0, 0.0]
    var strokeWidth: CGFloat = 0.0035
    /// Source-video dimensions in pixels (for UV normalization of cursor position).
    var sourceSize: CGSize = CGSize(width: 1920, height: 1080)
    /// Whether to hide the cursor when it hasn't moved in > 3 seconds (Screen Studio behavior).
    var autoHideIdleSeconds: Double = 3.0

    private var pipeline: MTLRenderPipelineState?
    private var sampler: MTLSamplerState?
    private let smoother = CursorSmoothingEffect()

    func load(samples: [CursorSample]) { smoother.load(samples) }

    func prepare(context: EffectContext) throws {
        pipeline = try context.makePipeline(fragment: "frag_cursor")
        sampler = context.linearSampler
    }

    func encode(_ commandBuffer: MTLCommandBuffer,
                input: MTLTexture,
                output: MTLTexture,
                time: CMTime,
                viewport: CGSize) {
        guard let pipeline, let sampler else { return }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = output
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(input, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)

        let posPx = smoother.sample(at: time)
        let w = max(1, sourceSize.width)
        let h = max(1, sourceSize.height)
        let uv = SIMD2<Float>(Float(posPx.x / w), Float(posPx.y / h))
        let aspect = Float(viewport.width / max(1, viewport.height))

        var u = CursorUniforms(
            position: uv,
            size: Float(size),
            aspect: aspect,
            fill: fill,
            stroke: stroke,
            strokeWidth: Float(strokeWidth)
        )
        enc.setFragmentBytes(&u, length: MemoryLayout<CursorUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }
}

/// Mirror of Metal `CursorUniforms`.
struct CursorUniforms {
    var position: SIMD2<Float>
    var size: Float
    var aspect: Float
    var fill: SIMD3<Float>
    var stroke: SIMD3<Float>
    var strokeWidth: Float
    // Padding so Metal's simd alignment matches (float3 aligns to 16)
    var _pad: Float = 0
}
