import CoreGraphics
import CoreMedia
import Foundation
import Metal

/// Composites the input ("screen content") into a rounded rectangle on top of a gradient
/// background, with a soft drop shadow. One-pass shader.
///
/// Padding is expressed as the fraction of the canvas that's reserved for background on each edge.
/// `cornerRadius` is in UV (normalized by canvas short edge).
final class MockupFrameEffect: Effect {
    let name = "MockupFrame"

    struct Settings {
        var paddingRatio: CGFloat = 0.06        // 6% of canvas on each side
        var cornerRadius: CGFloat = 0.02        // 2% corner radius (UV)
        var shadowStrength: CGFloat = 0.6
        var shadowSpread: CGFloat = 0.06
        var bgTop: SIMD3<Float>    = [0.09, 0.07, 0.14]
        var bgBottom: SIMD3<Float> = [0.02, 0.02, 0.05]
    }

    var settings = Settings()

    private var pipeline: MTLRenderPipelineState?
    private var sampler: MTLSamplerState?

    func prepare(context: EffectContext) throws {
        pipeline = try context.makePipeline(fragment: "frag_mockup")
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

        let pad = Float(settings.paddingRatio)
        var u = MockupUniforms(
            canvasSize: SIMD2(Float(viewport.width), Float(viewport.height)),
            contentRectMin: SIMD2(pad, pad),
            contentRectMax: SIMD2(1 - pad, 1 - pad),
            cornerRadius: Float(settings.cornerRadius),
            bgTop: settings.bgTop,
            bgBottom: settings.bgBottom,
            shadowStrength: Float(settings.shadowStrength),
            shadowSpread: Float(settings.shadowSpread)
        )
        enc.setFragmentBytes(&u, length: MemoryLayout<MockupUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }
}

struct MockupUniforms {
    var canvasSize: SIMD2<Float>
    var contentRectMin: SIMD2<Float>
    var contentRectMax: SIMD2<Float>
    var cornerRadius: Float
    var bgTop: SIMD3<Float>
    var bgBottom: SIMD3<Float>
    var shadowStrength: Float
    var shadowSpread: Float
    var _pad: Float = 0
}
