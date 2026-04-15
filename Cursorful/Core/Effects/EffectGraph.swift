import CoreMedia
import Foundation
import Metal

/// Protocol every visual effect implements. One encode pass: sample from `input`, write to `output`.
protocol Effect: AnyObject {
    var name: String { get }
    func prepare(context: EffectContext) throws
    func encode(_ commandBuffer: MTLCommandBuffer,
                input: MTLTexture,
                output: MTLTexture,
                time: CMTime,
                viewport: CGSize)
}

/// Linear chain of effects. Caller prepares once, then calls `render` per frame.
///
/// Threading / lifetime:
/// - Intermediate textures borrowed from `context.textureCache` are NOT released synchronously
///   after `encode` — that would let the pool hand the same texture out to another borrower while
///   the GPU is still reading from it (write-after-read hazard).
/// - Instead, we accumulate the list of borrowed intermediates and release them via
///   `commandBuffer.addCompletedHandler` so the pool only sees them again after the GPU is done.
final class EffectGraph {
    private(set) var effects: [Effect] = []
    private let context: EffectContext

    init(context: EffectContext) {
        self.context = context
    }

    func setEffects(_ effects: [Effect]) throws {
        self.effects = effects
        for e in effects { try e.prepare(context: context) }
    }

    func render(input: MTLTexture,
                output: MTLTexture,
                time: CMTime,
                commandBuffer: MTLCommandBuffer,
                viewport: CGSize) {
        let w = output.width
        let h = output.height

        if effects.isEmpty {
            blit(commandBuffer: commandBuffer, src: input, dst: output)
            return
        }

        // Borrowed intermediates — returned to the pool only after the GPU finishes this buffer.
        var borrowed: [MTLTexture] = []

        var current = input
        for (i, effect) in effects.enumerated() {
            let dst: MTLTexture
            if i == effects.count - 1 {
                dst = output
            } else {
                guard let mid = context.textureCache.borrow(width: w, height: h) else { return }
                borrowed.append(mid)
                dst = mid
            }
            effect.encode(commandBuffer, input: current, output: dst, time: time, viewport: viewport)
            current = dst
        }

        // Release-back-to-pool after GPU completion.
        if !borrowed.isEmpty {
            let cache = context.textureCache
            commandBuffer.addCompletedHandler { _ in
                for t in borrowed { cache.release(t) }
            }
        }
    }

    private func blit(commandBuffer: MTLCommandBuffer, src: MTLTexture, dst: MTLTexture) {
        guard let enc = commandBuffer.makeBlitCommandEncoder() else { return }
        let size = MTLSize(width: min(src.width, dst.width),
                           height: min(src.height, dst.height), depth: 1)
        enc.copy(from: src,
                 sourceSlice: 0, sourceLevel: 0,
                 sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                 sourceSize: size,
                 to: dst,
                 destinationSlice: 0, destinationLevel: 0,
                 destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        enc.endEncoding()
    }
}
