#include <metal_stdlib>
using namespace metal;

// A textured quad placed in normalized device coordinates.
struct QuadUniforms {
    float2 scale;   // half-size of the quad in NDC
    float2 offset;  // centre of the quad in NDC
    float2 uvScale;
    float2 uvOffset;
};

struct QuadVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex QuadVertexOut quad_vertex(uint vid [[vertex_id]],
                                 constant QuadUniforms &uniforms [[buffer(0)]]) {
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    const float2 uvs[4] = { float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0) };
    QuadVertexOut out;
    out.position = float4(corners[vid] * uniforms.scale + uniforms.offset, 0.0, 1.0);
    out.uv = uvs[vid] * uniforms.uvScale + uniforms.uvOffset;
    return out;
}

// Primary surface: opaque (xRGB surfaces carry no meaningful alpha).
fragment float4 surface_fragment(QuadVertexOut in [[stage_in]],
                                 texture2d<float> surface [[texture(0)]],
                                 sampler surfaceSampler [[sampler(0)]],
                                 constant QuadUniforms &uniforms [[buffer(0)]]) {
    // Clamp linear filtering to the chosen head's edge texels, so a neighboring
    // head cannot bleed through when this crop is enlarged.
    float2 halfTexel = min(float2(0.5) / float2(surface.get_width(), surface.get_height()), uniforms.uvScale * 0.5);
    float2 uv = clamp(in.uv, uniforms.uvOffset + halfTexel,
                      uniforms.uvOffset + uniforms.uvScale - halfTexel);
    return float4(surface.sample(surfaceSampler, uv).rgb, 1.0);
}

// Server-mode cursor overlay: premultiplied BGRA, blended source-over.
fragment float4 cursor_fragment(QuadVertexOut in [[stage_in]],
                                texture2d<float> cursor [[texture(0)]],
                                sampler cursorSampler [[sampler(0)]]) {
    return cursor.sample(cursorSampler, in.uv);
}
