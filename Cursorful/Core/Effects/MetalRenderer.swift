import CoreMedia
import Foundation
import Metal
import MetalKit

/// Helper that draws an MTLTexture into an MTKView drawable.
final class MetalRenderer {
    let context: EffectContext
    private var copyPipeline: MTLRenderPipelineState?

    init(context: EffectContext) {
        self.context = context
        self.copyPipeline = try? context.makePipeline(fragment: "frag_copy")
    }

    func drawTexture(_ texture: MTLTexture, in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cb = context.queue.makeCommandBuffer(),
              let pipeline = copyPipeline,
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }

        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(texture, index: 0)
        enc.setFragmentSamplerState(context.linearSampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()

        cb.present(drawable)
        cb.commit()
    }
}
