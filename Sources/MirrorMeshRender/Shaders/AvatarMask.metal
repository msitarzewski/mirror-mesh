#include <metal_stdlib>
using namespace metal;

// Stylized cartoon-face mask. Rendered as a single quad covering the upper-right corner of the
// frame; the fragment shader composes the face from analytic primitives driven by blendshapes.

struct AvatarUniforms {
    float2 rectOriginClip;  // bottom-left of the quad in clip space (-1..1)
    float2 rectSizeClip;    // size of the quad in clip space (0..2)
    float jawOpen;
    float browInnerUp;
    float browDownLeft;
    float browDownRight;
    float eyeBlinkLeft;
    float eyeBlinkRight;
    float mouthSmileLeft;
    float mouthSmileRight;
};

struct AvatarVOut {
    float4 position [[position]];
    float2 local;   // 0..1 within the avatar quad
};

vertex AvatarVOut avatar_vertex(uint vid [[vertex_id]],
                                constant AvatarUniforms& u [[buffer(0)]]) {
    float2 corners[4] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(1.0, 1.0)
    };
    float2 c = corners[vid];
    float2 clipPos = u.rectOriginClip + c * u.rectSizeClip;

    AvatarVOut out;
    out.position = float4(clipPos, 0.0, 1.0);
    out.local = c;
    return out;
}

static inline float sdEllipse(float2 p, float2 r) {
    // Cheap normalized-distance approximation; good enough for stylized soft edges.
    float2 q = p / max(r, float2(1e-4));
    return length(q) - 1.0;
}

static inline float softMask(float sd, float aa) {
    return saturate(1.0 - smoothstep(-aa, aa, sd));
}

fragment float4 avatar_fragment(AvatarVOut in [[stage_in]],
                                constant AvatarUniforms& u [[buffer(0)]]) {
    // Local space: face center at (0.5, 0.55); range roughly [0,1].
    float2 p = in.local;

    float aa = 0.01;

    // Head: a vertical ellipse.
    float2 headCenter = float2(0.5, 0.55);
    float2 headRadii  = float2(0.36, 0.42);
    float sdHead = sdEllipse(p - headCenter, headRadii);
    float headMask = softMask(sdHead, aa);
    if (headMask <= 0.0) discard_fragment();

    float3 skin = float3(1.00, 0.86, 0.70);
    float3 outline = float3(0.10, 0.10, 0.12);
    float3 col = skin;

    // Head outline ring.
    float ring = smoothstep(-0.012, 0.0, sdHead) * smoothstep(0.012, 0.0, sdHead);
    col = mix(col, outline, ring);

    // Brows: vertical offset driven by browInnerUp (+y up in local space) and brow-down per side.
    float browY = 0.74 + 0.04 * u.browInnerUp;
    float browYL = browY - 0.05 * u.browDownLeft;
    float browYR = browY - 0.05 * u.browDownRight;
    float2 browRadii = float2(0.09, 0.012);

    float sdBrowL = sdEllipse(p - float2(0.34, browYL), browRadii);
    float sdBrowR = sdEllipse(p - float2(0.66, browYR), browRadii);
    float browMask = max(softMask(sdBrowL, aa), softMask(sdBrowR, aa));
    col = mix(col, outline, browMask);

    // Eyes: ellipses; vertical radius shrinks with blink coefficient.
    float lidL = 1.0 - clamp(u.eyeBlinkLeft,  0.0, 1.0);
    float lidR = 1.0 - clamp(u.eyeBlinkRight, 0.0, 1.0);
    float2 eyeBaseR = float2(0.06, 0.045);
    float2 eyeRadiiL = float2(eyeBaseR.x, max(eyeBaseR.y * lidL, 0.003));
    float2 eyeRadiiR = float2(eyeBaseR.x, max(eyeBaseR.y * lidR, 0.003));

    float sdEyeL = sdEllipse(p - float2(0.34, 0.63), eyeRadiiL);
    float sdEyeR = sdEllipse(p - float2(0.66, 0.63), eyeRadiiR);
    float eyeMask = max(softMask(sdEyeL, aa), softMask(sdEyeR, aa));
    col = mix(col, float3(0.05, 0.05, 0.08), eyeMask);

    // Mouth: jaw drives vertical opening; smile lifts mouth corners by warping local x.
    float openY = 0.02 + 0.10 * clamp(u.jawOpen, 0.0, 1.0);
    float smile = 0.5 * (u.mouthSmileLeft + u.mouthSmileRight);
    float2 mouthC = float2(0.5, 0.42);
    float2 mouthRel = p - mouthC;
    // Bend the mouth so corners lift with smile coefficient.
    mouthRel.y -= smile * 0.06 * (1.0 - mouthRel.x * mouthRel.x * 25.0);
    float2 mouthRadii = float2(0.12, max(openY, 0.012));
    float sdMouth = sdEllipse(mouthRel, mouthRadii);
    float mouthMask = softMask(sdMouth, aa);
    col = mix(col, float3(0.40, 0.10, 0.12), mouthMask);

    return float4(col, headMask);
}
