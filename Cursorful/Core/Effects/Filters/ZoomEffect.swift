import CoreGraphics
import CoreMedia
import Foundation
import Metal

/// Zoom/pan effect. Samples source at a UV offset + scale.
final class ZoomEffect: Effect {
    let name = "Zoom"

    private var pipeline: MTLRenderPipelineState?
    private var sampler: MTLSamplerState?

    /// Current sample to apply. Populated by the caller each frame from the zoom track.
    var sample: ZoomSample = .identity

    func prepare(context: EffectContext) throws {
        pipeline = try context.makePipeline(fragment: "frag_zoom")
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

        var u = ZoomUniforms(
            center: SIMD2(Float(sample.centerUV.x), Float(sample.centerUV.y)),
            scale: Float(sample.scale),
            pad: 0
        )
        enc.setFragmentBytes(&u, length: MemoryLayout<ZoomUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }
}

/// Mirror of the Metal-side `ZoomUniforms` struct.
struct ZoomUniforms {
    var center: SIMD2<Float>
    var scale: Float
    var pad: Float
}
