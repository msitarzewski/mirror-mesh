#include <metal_stdlib>
using namespace metal;

// Uniforms for the triangulated face-mesh pass. `style` controls fragment behaviour:
//   0 = wireframe (output only on triangle edges via barycentric coords)
//   1 = filled    (solid color across the triangle)
struct FaceMeshUniforms {
    float4 color;
    uint   style;
    float  edgeThicknessPx;   // wireframe edge softness control
    float  viewportWidth;
    float  viewportHeight;
};

struct FaceMeshVOut {
    float4 position [[position]];
    float3 bary;
    float4 color;
    uint   style;
    float  edgeFeather;
};

// `landmarks` is a flat buffer of 76 float2s in normalized image space (origin top-left).
// `vid` indexes that buffer (after CPU expansion to a non-indexed vertex stream); barycentric
// coords are emitted by the vertex's position within its triangle (vid % 3).
vertex FaceMeshVOut face_mesh_vertex(uint vid [[vertex_id]],
                                     const device float2* landmarks [[buffer(0)]],
                                     const device ushort* indices [[buffer(1)]],
                                     constant FaceMeshUniforms& u [[buffer(2)]]) {
    ushort lmIdx = indices[vid];
    float2 uv = landmarks[lmIdx];

    // Image space (origin top-left, [0,1]) → clip space (origin center, +y up).
    float2 clip = float2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);

    // Barycentric pattern picked from the triangle-local vertex index.
    uint corner = vid % 3u;
    float3 bary = float3(0.0);
    bary[corner] = 1.0;

    // Feather scales with the smaller viewport edge so the wireframe looks consistent
    // regardless of output resolution.
    float minDim = max(min(u.viewportWidth, u.viewportHeight), 1.0);
    float feather = max(u.edgeThicknessPx, 0.5) / minDim;

    FaceMeshVOut out;
    out.position = float4(clip, 0.0, 1.0);
    out.bary = bary;
    out.color = u.color;
    out.style = u.style;
    out.edgeFeather = feather;
    return out;
}

fragment float4 face_mesh_fragment(FaceMeshVOut in [[stage_in]]) {
    if (in.style == 1u) {
        // Filled mode: solid color, optional alpha from uniform.
        return in.color;
    }
    // Wireframe mode: keep fragments near any of the three triangle edges.
    // Edge distance = the smallest barycentric coord (rises from 0 on an edge).
    float d = min(in.bary.x, min(in.bary.y, in.bary.z));
    float a = 1.0 - smoothstep(0.0, in.edgeFeather, d);
    if (a <= 0.001) discard_fragment();
    return float4(in.color.rgb, in.color.a * a);
}
