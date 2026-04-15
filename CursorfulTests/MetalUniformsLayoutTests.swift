import XCTest
@testable import Cursorful

/// Guardrail tests: if someone adds a field to an effect's uniform struct without updating the
/// matching Metal struct (or vice versa), stride will shift and the shader will read garbage.
/// These asserts pin the expected stride for each uniform.
///
/// Reference (Metal Shading Language Specification):
/// - `float2` : align 8,  size 8
/// - `float3` : align 16, size 16  (padded from 12 bytes)
/// - `float`  : align 4,  size 4
/// - Struct stride = round_up(end_offset_of_last_member, max_alignment_in_struct).
final class MetalUniformsLayoutTests: XCTestCase {

    func testZoomUniformsStride() {
        // center(f2 @ 0, 8) + scale(f @ 8, 4) + pad(f @ 12, 4) = 16
        XCTAssertEqual(MemoryLayout<ZoomUniforms>.stride, 16)
    }

    func testCursorUniformsStride() {
        // position(f2 @ 0, 8) + size(f @ 8, 4) + aspect(f @ 12, 4) = 16
        // fill(f3, align 16 → 16..32) + stroke(f3 @ 32..48)
        // strokeWidth(f @ 48, 4) + _pad(f @ 52, 4) = 56, rounded to 64 (max align 16)
        XCTAssertEqual(MemoryLayout<CursorUniforms>.stride, 64)
    }

    func testRippleUniformsStride() {
        // center(f2 @ 0, 8) + age(f @ 8, 4) + maxRadiusUV(f @ 12, 4) + aspect(f @ 16, 4)
        // align 16 pad → 20..32, tint(f3 @ 32..48). Stride 48 (already 16-aligned).
        XCTAssertEqual(MemoryLayout<RippleUniforms>.stride, 48)
    }

    func testMockupUniformsStride() {
        // canvasSize(f2, 0..8) + contentRectMin(f2, 8..16) + contentRectMax(f2, 16..24)
        // cornerRadius(f, 24..28) + align-16 pad → 28..32
        // bgTop(f3, 32..48) + bgBottom(f3, 48..64)
        // shadowStrength(f, 64..68) + shadowSpread(f, 68..72) + _pad(f, 72..76) = 76
        // Round up to multiple of 16 → 80
        XCTAssertEqual(MemoryLayout<MockupUniforms>.stride, 80)
    }
}
