#include <metal_stdlib>
using namespace metal;

// MARK: - PhotorealOverlay pass
//
// Composites the photoreal generator's output (256x256 or 512x512 RGB) over the live
// camera passthrough at the face bounding-box location each frame. Replaces the v1.0
// "substitute the entire camera buffer" approach that was aspect-stretching a 256x256
// square to 640x360 and discarding the user's actual background.
//
// The vertex shader draws a 4-vertex triangle-strip quad whose clip-space extent is
// defined by `bboxNDC` (xy = bottom-left in NDC [-1,1], zw = width/height in NDC). The
// fragment shader samples the photoreal texture at quad-local UVs and feathers the
// edges with a soft-rect smoothstep so the seam between camera pixels and the photoreal
// face fades smoothly rather than cutting hard.
//
// Layout matches `PhotorealOverlayUniforms` in PhotorealOverlay.swift; any change must
// be reflected on both sides. Composite uses standard premultiplied source-over blend
// (configured on the pipeline descriptor in Swift).

struct PhotorealOverlayUniforms {
    float4 bboxNDC;        // (x, y) = bottom-left in NDC, (z, w) = width, height in NDC
    float  opacity;        // global multiplier on the final alpha
    float  edgeFeather;    // 0..0.5 - fraction of bbox size to feather inward from each edge
    float  _pad0;
    float  _pad1;
};

struct PhotorealVOut {
    float4 position [[position]];
    float2 quadUV;          // [0,1] across the quad - used both for texture sample and feather
};

vertex PhotorealVOut photoreal_overlay_vertex(uint vid [[vertex_id]],
                                              constant PhotorealOverlayUniforms& u [[buffer(0)]]) {
    // Triangle-strip corners in quad-local space (matches Passthrough.metal corner order).
    float2 corners[4] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(1.0, 1.0)
    };
    float2 c = corners[vid];

    // Project quad corner into NDC using the bbox uniform.
    float2 ndc = float2(u.bboxNDC.x + c.x * u.bboxNDC.z,
                        u.bboxNDC.y + c.y * u.bboxNDC.w);

    PhotorealVOut out;
    out.position = float4(ndc, 0.0, 1.0);
    // Texture sample UVs - photoreal generator output has origin top-left, so flip Y.
    // c.y == 0 is the bottom of the NDC quad (which corresponds to the bottom of the
    // photoreal image when the bbox is mapped through "y down -> y up" in Swift); we
    // want u.v sample to come from the top when c.y == 1.0.
    out.quadUV = float2(c.x, 1.0 - c.y);
    return out;
}

fragment float4 photoreal_overlay_fragment(PhotorealVOut in [[stage_in]],
                                           constant PhotorealOverlayUniforms& u [[buffer(0)]],
                                           texture2d<float> photorealTex [[texture(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float4 rgb = photorealTex.sample(s, in.quadUV);

    // Soft-rect edge feather. Compute the distance from each edge of the quad in [0,1]
    // space, then smoothstep so the band `edgeFeather` wide on every side ramps alpha
    // from 0 (at the edge) to 1 (inside). The smaller of the four ramps wins so the
    // four corners receive the correct rounded fall-off.
    float feather = max(u.edgeFeather, 1e-4);
    // quadUV is the texture-sample UV (top-left origin); rebuild "distance from edge"
    // by symmetrizing — the result is identical whichever vertical convention we use.
    float dx = min(in.quadUV.x, 1.0 - in.quadUV.x);
    float dy = min(in.quadUV.y, 1.0 - in.quadUV.y);
    float edgeAlpha = smoothstep(0.0, feather, min(dx, dy));

    float alpha = rgb.a * edgeAlpha * u.opacity;
    // Premultiply so the source-over blend (configured in Swift) composites correctly
    // against the camera-passthrough background.
    return float4(rgb.rgb * alpha, alpha);
}
