import CoreVideo
import Foundation
import Metal

/// A thin pool that lets us:
///   1. Wrap a CVPixelBuffer → MTLTexture (for zero-copy uploads from AVAssetReader).
///   2. Allocate a pool of transient render targets for ping-ponging between effects.
final class TextureCache {
    private let device: MTLDevice
    private var cvCache: CVMetalTextureCache?
    private var pool: [MTLTexture] = []
    private let poolQueue = DispatchQueue(label: "com.cursorful.textures")

    init(device: MTLDevice) {
        self.device = device
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cvCache)
    }

    /// Wrap a pixel buffer as an MTL texture without copying.
    func texture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let cache = cvCache else { return nil }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        var ref: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .bgra8Unorm, w, h, 0, &ref
        )
        guard status == kCVReturnSuccess, let ref else { return nil }
        return CVMetalTextureGetTexture(ref)
    }

    /// Borrow a transient BGRA texture of `size` px. Caller returns it via `release`.
    func borrow(width: Int, height: Int) -> MTLTexture? {
        return poolQueue.sync {
            if let idx = pool.firstIndex(where: { $0.width == width && $0.height == height }) {
                return pool.remove(at: idx)
            }
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
            )
            d.usage = [.renderTarget, .shaderRead, .shaderWrite]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
    }

    func release(_ tex: MTLTexture) {
        poolQueue.sync { pool.append(tex) }
    }

    func flush() {
        if let cache = cvCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }
}
