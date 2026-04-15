#include <metal_stdlib>
using namespace metal;

// =================================================================================================
// Common vertex shader: full-screen triangle strip with optional affine transform for zoom/pan.
// Input: vertex index 0..3 generating a quad in NDC.
// =================================================================================================

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// Uniforms shared by most effects (linear transform in UV space).
struct ZoomUniforms {
    float2 center;      // zoom center in normalized UV
    float  scale;       // 1.0 = no zoom
    float  _pad;
};

vertex VertexOut vtx_quad(uint id [[vertex_id]]) {
    // Two triangles as a triangle strip: (0,0)(1,0)(0,1)(1,1)
    float2 uv = float2((id & 1u) ? 1.0 : 0.0,
                       (id & 2u) ? 1.0 : 0.0);
    float2 pos = float2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
    VertexOut out;
    out.position = float4(pos, 0.0, 1.0);
    out.uv = uv;
    return out;
}

// =================================================================================================
// Copy: passthrough
// =================================================================================================
fragment float4 frag_copy(VertexOut v [[stage_in]],
                          texture2d<float> src [[texture(0)]],
                          sampler smp [[sampler(0)]]) {
    return src.sample(smp, v.uv);
}

// =================================================================================================
// Zoom: sample src at transformed uv. Clamps to edge via sampler state.
// =================================================================================================
fragment float4 frag_zoom(VertexOut v [[stage_in]],
                          texture2d<float> src [[texture(0)]],
                          sampler smp [[sampler(0)]],
                          constant ZoomUniforms &u [[buffer(0)]]) {
    // uv' = (uv - center) / scale + center
    float2 uv = (v.uv - u.center) / max(u.scale, 0.0001) + u.center;
    return src.sample(smp, uv);
}

// =================================================================================================
// Click ripple: additive white ring centered at `center` (UV), radius grows with age.
// =================================================================================================
struct RippleUniforms {
    float2 center;         // in UV
    float  age;            // 0..1 (0 = just clicked, 1 = fully faded)
    float  maxRadiusUV;    // maximum radius in UV, fraction of viewport shortest side
    float  aspect;         // width / height
    float3 tint;
};

fragment float4 frag_ripple(VertexOut v [[stage_in]],
                            texture2d<float> src [[texture(0)]],
                            sampler smp [[sampler(0)]],
                            constant RippleUniforms &u [[buffer(0)]]) {
    float4 base = src.sample(smp, v.uv);
    if (u.age >= 1.0 || u.age < 0.0) return base;

    float2 d = (v.uv - u.center);
    d.x *= u.aspect;
    float dist = length(d);
    float radius = mix(0.0, u.maxRadiusUV, u.age);
    float thickness = 0.008 + 0.02 * (1.0 - u.age);
    float ringLo = radius - thickness;
    float ringHi = radius + thickness;
    float ring = smoothstep(ringLo, radius, dist) * (1.0 - smoothstep(radius, ringHi, dist));
    float alpha = ring * (1.0 - u.age);
    return base + float4(u.tint * alpha, alpha);
}

// =================================================================================================
// Cursor overlay: draws an enlarged "arrow" cursor sprite at a position.
// For simplicity we draw a stylized pointer in pure shader math (no sprite texture needed),
// which is sharp at any resolution.
// =================================================================================================
struct CursorUniforms {
    float2 position;    // UV
    float  size;        // half-height in UV (relative to viewport short edge)
    float  aspect;      // viewport width / height
    float3 fill;        // cursor fill color
    float3 stroke;      // outline color
    float  strokeWidth; // in UV
};

float cursorSDF(float2 p, float size) {
    // Classic macOS-style arrow defined as the intersection of three lines + tail.
    // We draw a triangle pointing top-left: tip at (0,0), base at (0, 2s) and (2s, 2s) rotated.
    // Transform so (0,0) is the tip; scale by size.
    float2 uv = p / size;
    // Rotate -135deg... actually we approximate with an asymmetric triangle.
    // Triangle vertices (clockwise): (0,0), (0.7, 1.0), (0.25, 0.9). Use barycentric.
    float2 a = float2(0.0, 0.0);
    float2 b = float2(0.85, 1.05);
    float2 c = float2(0.30, 1.00);
    float2 d = float2(0.45, 1.35);
    float2 e = float2(0.15, 1.35);

    // Point-in-polygon via signed area (CW assumed). Inline instead of lambda (Metal has no lambdas).
    float d1 = (uv.x - b.x) * (a.y - b.y) - (a.x - b.x) * (uv.y - b.y);
    float d2 = (uv.x - c.x) * (b.y - c.y) - (b.x - c.x) * (uv.y - c.y);
    float d3 = (uv.x - a.x) * (c.y - a.y) - (c.x - a.x) * (uv.y - a.y);
    bool hasNeg = (d1 < 0) || (d2 < 0) || (d3 < 0);
    bool hasPos = (d1 > 0) || (d2 > 0) || (d3 > 0);
    bool inBody = !(hasNeg && hasPos);

    float e1 = (uv.x - d.x) * (c.y - d.y) - (c.x - d.x) * (uv.y - d.y);
    float e2 = (uv.x - e.x) * (d.y - e.y) - (d.x - e.x) * (uv.y - e.y);
    float e3 = (uv.x - c.x) * (e.y - c.y) - (e.x - c.x) * (uv.y - c.y);
    bool hasNeg2 = (e1 < 0) || (e2 < 0) || (e3 < 0);
    bool hasPos2 = (e1 > 0) || (e2 > 0) || (e3 > 0);
    bool inTail = !(hasNeg2 && hasPos2);

    return (inBody || inTail) ? 1.0 : 0.0;
}

fragment float4 frag_cursor(VertexOut v [[stage_in]],
                            texture2d<float> src [[texture(0)]],
                            sampler smp [[sampler(0)]],
                            constant CursorUniforms &u [[buffer(0)]]) {
    float4 base = src.sample(smp, v.uv);
    float2 rel = v.uv - u.position;
    rel.x *= u.aspect;
    if (abs(rel.x) > u.size * 1.6 || abs(rel.y) > u.size * 1.6) return base;

    float inside  = cursorSDF(rel, u.size);
    float outside = cursorSDF(rel, u.size + u.strokeWidth);
    float outline = clamp(outside - inside, 0.0, 1.0);

    float4 color = base;
    color.rgb = mix(color.rgb, u.stroke, outline);
    color.rgb = mix(color.rgb, u.fill,   inside);
    return color;
}

// =================================================================================================
// Mockup + background + shadow: composite src (the zoomed/cursored screen) onto a background
// with rounded corners + drop shadow.
// Input texture is the "screen content" already at its desired on-canvas size.
// =================================================================================================

struct MockupUniforms {
    float2 canvasSize;      // px
    float2 contentRectMin;  // UV of the content rect (top-left)
    float2 contentRectMax;  // UV of the content rect (bottom-right)
    float  cornerRadius;    // in UV (normalized by canvas short edge)
    float3 bgTop;
    float3 bgBottom;
    float  shadowStrength;  // 0..1
    float  shadowSpread;    // in UV
};

float roundedRectSDF(float2 p, float2 rectMin, float2 rectMax, float radius) {
    float2 d;
    d.x = max(max(rectMin.x - p.x, p.x - rectMax.x), 0.0);
    d.y = max(max(rectMin.y - p.y, p.y - rectMax.y), 0.0);
    // Corner rounding: shrink the rect by radius, compute distance, subtract radius.
    // For in-rect we compute negative SDF via manhattan floor.
    float outside = length(d);
    // Inside distance
    float insideX = min(p.x - rectMin.x, rectMax.x - p.x);
    float insideY = min(p.y - rectMin.y, rectMax.y - p.y);
    float inside = -min(insideX, insideY);
    float sdf = (d.x > 0.0 || d.y > 0.0) ? outside : inside;
    return sdf - radius;
}

fragment float4 frag_mockup(VertexOut v [[stage_in]],
                            texture2d<float> src [[texture(0)]],
                            sampler smp [[sampler(0)]],
                            constant MockupUniforms &u [[buffer(0)]]) {
    // Background gradient
    float3 bg = mix(u.bgTop, u.bgBottom, v.uv.y);

    // Sample content if inside the content rect
    float2 min = u.contentRectMin;
    float2 max = u.contentRectMax;
    float sdf = roundedRectSDF(v.uv, min, max, u.cornerRadius);

    // Drop shadow: positive SDF (outside rect) gets darkened with Gaussian falloff.
    float shadow = exp(-pow(clamp(sdf, 0.0, 10.0) / u.shadowSpread, 2.0)) * u.shadowStrength;
    bg = bg * (1.0 - shadow * 0.6);

    if (sdf < 0.0) {
        // Inside content rect; sample from src at uv normalized within the rect.
        float2 cuv = (v.uv - min) / (max - min);
        float4 content = src.sample(smp, cuv);
        float mask = 1.0 - smoothstep(-0.0015, 0.0, sdf); // soft edge
        return float4(mix(bg, content.rgb, mask), 1.0);
    }
    return float4(bg, 1.0);
}
