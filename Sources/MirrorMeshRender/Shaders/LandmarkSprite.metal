#include <metal_stdlib>
using namespace metal;

// Per-instance landmark position in normalized image space (origin top-left, [0,1]).
struct LandmarkInstance {
    float2 uv;
};

struct LandmarkUniforms {
    float pointRadiusPx;
    float viewportWidth;
    float viewportHeight;
    float _pad;
    float4 color;
};

struct LandmarkVOut {
    float4 position [[position]];
    float2 local;       // -1..1 across the sprite quad
    float4 color;
};

vertex LandmarkVOut landmark_vertex(uint vid [[vertex_id]],
                                    uint iid [[instance_id]],
                                    const device LandmarkInstance* instances [[buffer(0)]],
                                    constant LandmarkUniforms& u [[buffer(1)]]) {
    float2 corners[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };
    float2 local = corners[vid];

    LandmarkInstance inst = instances[iid];

    // Map normalized image space (origin top-left) to clip space (origin center, +y up).
    float2 centerClip = float2(inst.uv.x * 2.0 - 1.0,
                               1.0 - inst.uv.y * 2.0);

    float2 halfSizeClip = float2(u.pointRadiusPx / max(u.viewportWidth, 1.0) * 2.0,
                                 u.pointRadiusPx / max(u.viewportHeight, 1.0) * 2.0);

    LandmarkVOut out;
    out.position = float4(centerClip + local * halfSizeClip, 0.0, 1.0);
    out.local = local;
    out.color = u.color;
    return out;
}

fragment float4 landmark_fragment(LandmarkVOut in [[stage_in]]) {
    float r = length(in.local);
    if (r > 1.0) discard_fragment();
    // Soft edge for a small antialiased disc.
    float a = smoothstep(1.0, 0.85, r);
    return float4(in.color.rgb, in.color.a * a);
}
