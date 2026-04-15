import CoreGraphics
import CoreMedia
import Foundation
import Metal

/// Renders expanding ring pulses at click positions. Each click produces one pulse that lives for
/// `lifetime` seconds; after that it fades to zero.
final class ClickRippleEffect: Effect {
    let name = "ClickRipple"

    var lifetime: Double = 0.6
    var maxRadiusUV: CGFloat = 0.12
    var tint: SIMD3<Float> = [1, 1, 1]
    var sourceSize: CGSize = CGSize(width: 1920, height: 1080)

    private var clicks: [ClickEvent] = []
    private var pipeline: MTLRenderPipelineState?
    private var sampler: MTLSamplerState?

    func load(clicks: [ClickEvent]) {
        self.clicks = clicks.filter { $0.isDown }.sorted { $0.time < $1.time }
    }

    func prepare(context: EffectContext) throws {
        pipeline = try context.makePipeline(fragment: "frag_ripple")
        sampler = context.linearSampler
    }

    func encode(_ commandBuffer: MTLCommandBuffer,
                input: MTLTexture,
                output: MTLTexture,
                time: CMTime,
                viewport: CGSize) {
        guard let pipeline, let sampler else { return }
        // Find the most recent click within `lifetime` seconds.
        let t = time.secondsOrZero
        let active = clicks.last(where: { $0.time.secondsOrZero <= t })
        var age: Float = 1.0
        var centerUV = SIMD2<Float>(0.5, 0.5)
        if let c = active {
            let dt = t - c.time.secondsOrZero
            if dt < lifetime {
                age = Float(dt / lifetime)
                centerUV = SIMD2(Float(c.position.x / sourceSize.width),
                                 Float(c.position.y / sourceSize.height))
            }
        }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = output
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(input, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)

        var u = RippleUniforms(
            center: centerUV,
            age: age,
            maxRadiusUV: Float(maxRadiusUV),
            aspect: Float(viewport.width / max(1, viewport.height)),
            tint: tint
        )
        enc.setFragmentBytes(&u, length: MemoryLayout<RippleUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }
}

struct RippleUniforms {
    var center: SIMD2<Float>
    var age: Float
    var maxRadiusUV: Float
    var aspect: Float
    var tint: SIMD3<Float>
}
