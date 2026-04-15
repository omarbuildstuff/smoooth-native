import CoreMedia
import Foundation
import Metal

/// Holds references to the Metal device, command queue, and shader library + caches used across
/// effects for the duration of a render session (preview or export).
final class EffectContext {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary
    let linearSampler: MTLSamplerState
    let clampedSampler: MTLSamplerState
    let textureCache: TextureCache

    enum Failure: Error {
        case noDevice
        case libraryLoadFailed
    }

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw Failure.noDevice }
        guard let queue = device.makeCommandQueue() else { throw Failure.noDevice }
        guard let library = device.makeDefaultLibrary() else { throw Failure.libraryLoadFailed }
        self.device = device
        self.queue = queue
        self.library = library

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        self.linearSampler = device.makeSamplerState(descriptor: sd)!

        let sd2 = MTLSamplerDescriptor()
        sd2.minFilter = .linear
        sd2.magFilter = .linear
        sd2.sAddressMode = .clampToEdge
        sd2.tAddressMode = .clampToEdge
        self.clampedSampler = device.makeSamplerState(descriptor: sd2)!

        self.textureCache = TextureCache(device: device)
    }

    func makePipeline(fragment: String) throws -> MTLRenderPipelineState {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction   = library.makeFunction(name: "vtx_quad")
        desc.fragmentFunction = library.makeFunction(name: fragment)
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.colorAttachments[0].isBlendingEnabled = false
        return try device.makeRenderPipelineState(descriptor: desc)
    }
}
