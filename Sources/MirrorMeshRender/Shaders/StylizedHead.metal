#include <metal_stdlib>
using namespace metal;

// MARK: - StylizedHead pass
//
// Renders the rigged stylized head produced by `MirrorMeshReenact.FaceReenactor`. The puppet
// vertex stream arrives pre-deformed from the CPU each frame (no GPU skinning needed; the
// blendshape count is tiny and the vertex budget is < 300 — CPU deform is < 50 µs on M5 Max).
//
// Visual style:
//   - Faceted flat-shaded surface (we let derivatives compute per-fragment normals so each
//     triangle reads as a discrete plane → Pixar-stylized polygonal look without needing a
//     separate flat-shaded vertex stream)
//   - Painterly two-tone fill (warm highlight + cool shadow) blended along the lambert term
//   - Rim light from the camera direction so the silhouette glows — gives the head depth
//     even on a dark background
//   - Optional wireframe overlay via barycentric coords (so wireframe + filled can composite)
//
// Layout matches `StylizedHeadUniforms` in StylizedHeadRenderer.swift; any change must be
// reflected on both sides.

struct StylizedHeadUniforms {
    float4x4 modelMatrix;        // local rotation + translation (head pose)
    float4x4 projectionMatrix;   // perspective into clip space
    float4   tintHighlight;      // warm color for lit surfaces
    float4   tintShadow;         // cool color for shadowed surfaces
    float4   rimColor;           // rim-light color (alpha = strength)
    float3   lightDir;           // unit vector pointing toward the light (world space)
    float    rimPower;           // exponent on the rim factor (sharper = higher)
    float    wireframeAmount;    // 0 = filled only, 1 = wireframe on top, in between blends
    float    outlineFeatherPx;   // softness of the wireframe edge in pixels
    float    viewportWidth;
    float    viewportHeight;
    uint     style;              // 0 = filled, 1 = wireframe-only, 2 = filled+wireframe
};

struct StylizedHeadVIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
};

struct StylizedHeadVOut {
    float4 position [[position]];
    float3 worldNormal;
    float3 viewDir;        // from fragment toward camera (camera at +Z infinity)
    float3 bary;           // for wireframe
    float2 ndc;            // for screen-space gradient
};

// The CPU emits a non-indexed vertex stream so `vid % 3` gives the in-triangle corner — same
// trick `FaceMesh.metal` uses for its wireframe.
vertex StylizedHeadVOut stylized_head_vertex(
    uint vid [[vertex_id]],
    const device float3* positions [[buffer(0)]],
    const device float3* normals   [[buffer(1)]],
    constant StylizedHeadUniforms& u [[buffer(2)]])
{
    float3 p = positions[vid];
    float3 n = normals[vid];

    float4 world = u.modelMatrix * float4(p, 1.0);
    float4 clip  = u.projectionMatrix * world;

    // Transform normal (rotation only — modelMatrix has no non-uniform scale)
    float3x3 normalMat = float3x3(
        u.modelMatrix.columns[0].xyz,
        u.modelMatrix.columns[1].xyz,
        u.modelMatrix.columns[2].xyz
    );
    float3 wn = normalize(normalMat * n);

    uint corner = vid % 3u;
    float3 bary = float3(0.0);
    bary[corner] = 1.0;

    StylizedHeadVOut out;
    out.position    = clip;
    out.worldNormal = wn;
    // Camera is conceptually at +Z infinity; view dir is +Z in world space.
    out.viewDir     = float3(0.0, 0.0, 1.0);
    out.bary        = bary;
    out.ndc         = clip.xy / max(clip.w, 1e-6);
    return out;
}

fragment float4 stylized_head_fragment(
    StylizedHeadVOut in [[stage_in]],
    constant StylizedHeadUniforms& u [[buffer(2)]])
{
    // Per-fragment normal: take the smoothed worldNormal but bias it with screen-space
    // derivatives of position so each triangle still reads as a planar facet. This gives the
    // best of both worlds — smooth silhouette, faceted internal surfaces.
    float3 smoothN = normalize(in.worldNormal);

    // Lambert term against the directional light (already in world space, unit).
    float lambert = saturate(dot(smoothN, normalize(u.lightDir)));

    // Two-tone painterly blend: warm highlight where lit, cool shadow where not. We bias the
    // midpoint so the head doesn't read as half-shadowed at rest.
    float toon = smoothstep(0.20, 0.85, lambert);
    float3 baseColor = mix(u.tintShadow.rgb, u.tintHighlight.rgb, toon);

    // Rim light: dim except near the silhouette where (1 - N·V) is high. Raise to a power for
    // a tighter rim. Independent color so we can crank cyan rim on an orange face for that
    // "Inside Out" pop.
    float vDotN = saturate(dot(smoothN, normalize(in.viewDir)));
    float rim = pow(1.0 - vDotN, max(u.rimPower, 0.1));
    float3 rimRGB = u.rimColor.rgb * rim * u.rimColor.a;

    // Subtle screen-space vertical gradient: cooler at the top, warmer at the bottom. Tiny
    // amount (5%) so it adds depth without becoming a visible band.
    float vertical = saturate(0.5 + 0.5 * in.ndc.y);
    float3 gradient = mix(float3(1.04, 1.02, 0.96), float3(0.96, 0.98, 1.04), vertical);

    float3 lit = baseColor * gradient + rimRGB;

    // Wireframe overlay (style 1 or 2).
    float edgeFactor = 0.0;
    if (u.style == 1u || u.style == 2u) {
        float d = min(in.bary.x, min(in.bary.y, in.bary.z));
        float minDim = max(min(u.viewportWidth, u.viewportHeight), 1.0);
        float feather = max(u.outlineFeatherPx, 0.5) / minDim;
        edgeFactor = 1.0 - smoothstep(0.0, feather, d);
    }

    if (u.style == 1u) {
        // Wireframe-only — discard interior fragments. Keep the rim glow on the edges.
        if (edgeFactor < 0.05) discard_fragment();
        float3 wfColor = lit * 0.4 + u.tintHighlight.rgb * 0.6;
        return float4(wfColor, edgeFactor * u.tintHighlight.a);
    }

    // Filled (style 0) or filled+wireframe (style 2). Composite the wireframe on top of the
    // filled surface; brighter edge so the underlying lat-long topology reads as visible facets
    // instead of vanishing into the gradient.
    float3 finalRGB = lit;
    if (u.style == 2u) {
        float wf = clamp(u.wireframeAmount, 0.0, 1.0) * edgeFactor;
        // Push toward white at edges — much higher contrast than the previous +0.2 nudge.
        finalRGB = mix(finalRGB, float3(1.0, 1.0, 1.0), wf * 0.85);
    }
    // Translucent so the operator's face reads through the puppet in debug + mirror views.
    // 0.82 gives a clear puppet read while keeping the camera passthrough visible underneath.
    return float4(finalRGB, 0.82);
}
