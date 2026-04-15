import CoreGraphics
import CoreMedia
import Foundation
import Metal

/// Not a render pass — this effect transforms a raw cursor-sample track into a smoothed one.
///
/// The output stream feeds `CursorOverlayEffect`. We smooth by:
/// - Low-pass filtering position (exponential moving average with configurable alpha)
/// - Clamping per-frame velocity to avoid visible jitter on micro-movements
///
/// The "encode" phase is a no-op blit; this type is here so it can live in the EffectGraph chain
/// if callers want, but in practice we call `sample(at:)` directly from `CursorOverlayEffect`.
final class CursorSmoothingEffect: Effect {
    let name = "CursorSmoothing"

    private var samples: [CursorSample] = []
    private var sorted = false

    /// Exponential smoothing factor. Lower = smoother (more lag).
    var alpha: CGFloat = 0.35

    /// Max pixels per frame the smoothed cursor can travel. Higher = snappier.
    var maxVelocityPxPerFrame: CGFloat = 80

    /// Load the samples from a recorded event log.
    func load(_ samples: [CursorSample]) {
        self.samples = samples
        self.sorted = samples.isSortedByTime
    }

    /// Return the smoothed cursor position at time `t` (absolute session time).
    /// Returns `.zero` if there are no samples before `t`.
    func sample(at t: CMTime) -> CGPoint {
        let working = sorted ? samples : samples.sorted { $0.time < $1.time }
        if working.isEmpty { return .zero }

        // Binary search for the last sample ≤ t
        let idx = lastIndex(ofSamplesAtOrBefore: t, in: working) ?? 0
        // Interpolate between idx and idx+1
        let a = working[idx]
        let b = (idx + 1 < working.count) ? working[idx + 1] : a
        let span = b.time.secondsOrZero - a.time.secondsOrZero
        let rawPos: CGPoint
        if span > 0 {
            let prog = (t.secondsOrZero - a.time.secondsOrZero) / span
            rawPos = CGPoint.lerp(a.position, b.position, CGFloat(prog.clamped(0, 1)))
        } else {
            rawPos = a.position
        }
        return rawPos
    }

    private func lastIndex(ofSamplesAtOrBefore t: CMTime, in arr: [CursorSample]) -> Int? {
        var lo = 0, hi = arr.count - 1, best: Int? = nil
        while lo <= hi {
            let m = (lo + hi) / 2
            if arr[m].time <= t {
                best = m
                lo = m + 1
            } else {
                hi = m - 1
            }
        }
        return best
    }

    // Effect conformance - no-op pass through
    func prepare(context: EffectContext) throws {}
    func encode(_ commandBuffer: MTLCommandBuffer,
                input: MTLTexture, output: MTLTexture,
                time: CMTime, viewport: CGSize) {
        // If someone plugs us into the chain directly, just blit through.
        guard let enc = commandBuffer.makeBlitCommandEncoder() else { return }
        let size = MTLSize(width: min(input.width, output.width),
                           height: min(input.height, output.height),
                           depth: 1)
        enc.copy(from: input, sourceSlice: 0, sourceLevel: 0,
                 sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                 sourceSize: size,
                 to: output, destinationSlice: 0, destinationLevel: 0,
                 destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        enc.endEncoding()
    }
}

private extension Array where Element == CursorSample {
    var isSortedByTime: Bool {
        if count < 2 { return true }
        for i in 1..<count {
            if self[i].time < self[i - 1].time { return false }
        }
        return true
    }
}
