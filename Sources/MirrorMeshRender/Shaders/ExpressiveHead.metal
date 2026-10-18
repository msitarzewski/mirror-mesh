#include <metal_stdlib>
using namespace metal;

// MARK: - ExpressiveHead pass
//
// A stylized head built entirely from signed-distance functions and raymarched per pixel.
// No mesh, no textures, no weights: the geometry below IS the asset, so every byte is
// reproducible from source (the same property `StylizedHead.swift` keeps for the classic rig).
//
// Inputs per frame:
//   • 52 ARKit coefficients in `BlendshapeKey.allCases` order (buffer 1). The index table below
//     is pinned against the Swift enum by `ExpressiveHeadTests.coefficientIndicesMatchSwiftEnum`.
//   • Head rotation rows + the head-local rectangle the quad covers (uniforms, buffer 0).
//
// Space conventions:
//   • Head-local: origin near the centre of the face, +x toward image-right, +y up, +z toward the
//     viewer. ~2.1 units crown-to-chin. "Left" coefficients drive the -x (image-left) side, the
//     same image-space convention the geometric solver uses.
//   • Camera space: head-local rotated by R (pose). Orthographic rays travel along -z.
//   • The neck lives in camera space so head roll/yaw doesn't drag the shoulders with it.
//
// Output: premultiplied colour over the camera passthrough (blend set up in Swift). Silhouette
// edges are antialiased from the ray's closest approach; the neck fades out toward the bottom.
//
// Likeness (optional, per consented identity — see PortraitAnalyzer): anatomy uniforms reshape
// the head to the portrait's proportions, a depth-derived relief map adds the person's surface
// detail, and the de-lit portrait is projected onto the skin through a skin-likeness mask. Both
// textures are sampled at the surface point's *rest* position (jaw opening undone), so they move
// with the face. Eyes, brows and hair stay procedural so blink, gaze and brow motion still work.
//
// Layout matches `ExpressiveHeadUniforms` in ExpressiveHeadRenderer.swift; any change must be
// reflected on both sides.

struct ExpressiveHeadUniforms {
    float4 rectNDC;      // (x, y) = bottom-left of the quad in NDC, (z, w) = size in NDC
    float4 localRect;    // head-local extents covered by the quad: (minX, minY, maxX, maxY)
    float4 rotRow0;      // rows of R (head-local → camera); .w unused
    float4 rotRow1;
    float4 rotRow2;
    float4 skinColor;    // linear RGB
    float4 hairColor;
    float4 irisColor;
    float4 lipColor;
    float4 keyLightDir;  // camera space, unit, toward the light
    float4 params;       // x = opacity, y = head-local units per pixel, z = max march steps, w = unused
    float4 anat0;        // browLift, noseTipY, noseWidth, mouthY
    float4 anat1;        // mouthHalfWidth, upperLip, lowerLip, chinShift
    float4 anat2;        // jawWidth, cheekWidth, eyeScale, unused
    float4 anat3;        // hairlineY, fringe (0/1), hairHeight, hairWidth
    float4 likeness;     // x = portrait albedo on (0/1), y = relief gain, z = hair colour from portrait (0/1)
    float4 uvRowU;       // portrait u = dot(uvRowU.xyz, (x, y, 1)) for head-local rest (x, y)
    float4 uvRowV;
};

constexpr sampler eh_samp(coord::normalized, address::clamp_to_zero, filter::linear);

// Indices into the coefficient buffer — `BlendshapeKey.allCases` order.
constant int EH_EYE_BLINK_L = 0;      // +1 → right
constant int EH_EYE_LOOK_DOWN_L = 2;
constant int EH_EYE_LOOK_IN_L = 4;
constant int EH_EYE_LOOK_OUT_L = 6;
constant int EH_EYE_LOOK_UP_L = 8;
constant int EH_EYE_SQUINT_L = 10;
constant int EH_EYE_WIDE_L = 12;
constant int EH_JAW_FORWARD = 14;
constant int EH_JAW_LEFT = 15;
constant int EH_JAW_RIGHT = 16;
constant int EH_JAW_OPEN = 17;
constant int EH_MOUTH_CLOSE = 18;
constant int EH_MOUTH_FUNNEL = 19;
constant int EH_MOUTH_PUCKER = 20;
constant int EH_MOUTH_LEFT = 21;
constant int EH_MOUTH_RIGHT = 22;
constant int EH_MOUTH_SMILE_L = 23;
constant int EH_MOUTH_FROWN_L = 25;
constant int EH_MOUTH_DIMPLE_L = 27;
constant int EH_MOUTH_STRETCH_L = 29;
constant int EH_MOUTH_ROLL_LOWER = 31;
constant int EH_MOUTH_ROLL_UPPER = 32;
constant int EH_MOUTH_SHRUG_LOWER = 33;
constant int EH_MOUTH_SHRUG_UPPER = 34;
constant int EH_MOUTH_PRESS_L = 35;
constant int EH_MOUTH_LOWER_DOWN_L = 37;
constant int EH_MOUTH_UPPER_UP_L = 39;
constant int EH_BROW_DOWN_L = 41;
constant int EH_BROW_INNER_UP = 43;
constant int EH_BROW_OUTER_UP_L = 44;
constant int EH_CHEEK_PUFF = 46;
constant int EH_CHEEK_SQUINT_L = 47;
constant int EH_NOSE_SNEER_L = 49;
constant int EH_TONGUE_OUT = 51;

// Materials returned by the scene map.
constant float EH_MAT_SKIN = 0.0;    // aux = lip weight, aux2 = mouth-interior weight
constant float EH_MAT_EYE = 1.0;
constant float EH_MAT_HAIR = 2.0;    // aux = strand groove, aux2 = 1 for brows
constant float EH_MAT_TEETH = 3.0;
constant float EH_MAT_TONGUE = 4.0;

// Fixed anatomy (head-local).
constant float3 EH_HINGE = float3(0.0, 0.02, -0.10);     // jaw pivot, roughly at the ear
constant float  EH_EYE_X = 0.30;
constant float  EH_EYE_Y = 0.10;
constant float  EH_EYE_Z = 0.575;
constant float  EH_EYE_R = 0.165;

// MARK: - Rig: coefficients → per-frame anatomy parameters

struct EHRig {
    float blink[2];
    float squint[2];
    float wide[2];
    float2 gaze;          // x toward image-right, y up — mirrors GazeChannels.decode in Swift
    float browInner[2];
    float browOuter[2];
    float browPull[2];
    float jawAngle;
    float lowerLipAngle;
    float3 jawShift;
    float corner[2];      // mouth-corner lift (smile − frown)
    float dimple[2];
    float press;
    float funnel;
    float pucker;
    float rollLower;
    float rollUpper;
    float cheekPuff;
    float cheekLift[2];
    float sneer[2];
    float tongue;
    float2 mouthHalfWidth;   // (image-left, image-right): one-sided smiles widen one side
    float3 upperLip;
    float3 lowerLip;
    // Per-identity anatomy (stock values reproduce the generic head).
    float browLift;
    float noseTipY;
    float noseWidth;
    float3 mouth;
    float2 lipH;          // upper, lower lip half-thickness
    float mouthBaseWidth;
    float chinShift;      // + = longer face
    float jawWidth;
    float cheekWidth;
    float eyeScale;
    float eyeR;
    float hairlineY;
    float fringe;
    float hairHeight;
    float hairWidth;
    float boundR;         // radius of the sphere that encloses the whole head (grows with the hair fit)
};

static inline float eh_saturate(float x) { return clamp(x, 0.0, 1.0); }

static float3 eh_jawRotate(float3 p, float angle) {
    float3 d = p - EH_HINGE;
    float c = cos(angle), s = sin(angle);
    return EH_HINGE + float3(d.x, d.y * c - d.z * s, d.y * s + d.z * c);
}

static EHRig eh_makeRig(constant float* c, constant ExpressiveHeadUniforms& u) {
    EHRig r;
    r.browLift = u.anat0.x; r.noseTipY = u.anat0.y; r.noseWidth = u.anat0.z;
    r.mouth = float3(0.0, u.anat0.w, 0.775);
    r.mouthBaseWidth = u.anat1.x; r.lipH = u.anat1.yz; r.chinShift = u.anat1.w;
    r.jawWidth = u.anat2.x; r.cheekWidth = u.anat2.y; r.eyeScale = u.anat2.z;
    r.eyeR = EH_EYE_R * r.eyeScale;
    r.hairlineY = u.anat3.x; r.fringe = u.anat3.y; r.hairHeight = u.anat3.z; r.hairWidth = u.anat3.w;
    r.boundR = 1.36 + 0.94 * max(r.hairHeight - 1.0, 0.0) + 0.87 * max(r.hairWidth - 1.0, 0.0);
    for (int s = 0; s < 2; s++) {
        r.blink[s] = eh_saturate(c[EH_EYE_BLINK_L + s]);
        r.squint[s] = eh_saturate(c[EH_EYE_SQUINT_L + s]);
        r.wide[s] = eh_saturate(c[EH_EYE_WIDE_L + s]);
        float browDown = eh_saturate(c[EH_BROW_DOWN_L + s]);
        r.browInner[s] = eh_saturate(c[EH_BROW_INNER_UP]) - 0.7 * browDown;
        r.browOuter[s] = eh_saturate(c[EH_BROW_OUTER_UP_L + s]) - 0.3 * browDown;
        r.browPull[s] = browDown;
        float smile = eh_saturate(c[EH_MOUTH_SMILE_L + s]);
        float frown = eh_saturate(c[EH_MOUTH_FROWN_L + s]);
        r.corner[s] = 0.110 * smile - 0.065 * frown;
        r.dimple[s] = eh_saturate(c[EH_MOUTH_DIMPLE_L + s]);
        r.cheekLift[s] = eh_saturate(c[EH_CHEEK_SQUINT_L + s] + 0.6 * smile);
        r.sneer[s] = eh_saturate(c[EH_NOSE_SNEER_L + s]);
    }

    // Conjugate gaze (GazeChannels.decode).
    float inL = c[EH_EYE_LOOK_IN_L], outL = c[EH_EYE_LOOK_OUT_L];
    float inR = c[EH_EYE_LOOK_IN_L + 1], outR = c[EH_EYE_LOOK_OUT_L + 1];
    float upL = c[EH_EYE_LOOK_UP_L], upR = c[EH_EYE_LOOK_UP_L + 1];
    float dnL = c[EH_EYE_LOOK_DOWN_L], dnR = c[EH_EYE_LOOK_DOWN_L + 1];
    r.gaze = clamp(float2(0.5 * ((inL - outL) + (outR - inR)),
                          0.5 * ((upL - dnL) + (upR - dnR))), -1.0, 1.0);

    float jawOpen = eh_saturate(c[EH_JAW_OPEN]);
    float mouthClose = eh_saturate(c[EH_MOUTH_CLOSE]);
    r.jawAngle = 0.34 * jawOpen;
    r.lowerLipAngle = r.jawAngle * (1.0 - 0.85 * mouthClose);
    float jawSide = eh_saturate(c[EH_JAW_RIGHT]) - eh_saturate(c[EH_JAW_LEFT]);
    r.jawShift = float3(0.05 * jawSide, 0.0, 0.05 * eh_saturate(c[EH_JAW_FORWARD]) + 0.10 * jawOpen);  // + condyle glide

    r.funnel = eh_saturate(c[EH_MOUTH_FUNNEL]);
    r.pucker = eh_saturate(c[EH_MOUTH_PUCKER]);
    r.rollLower = eh_saturate(c[EH_MOUTH_ROLL_LOWER]);
    r.rollUpper = eh_saturate(c[EH_MOUTH_ROLL_UPPER]);
    r.press = 0.5 * (eh_saturate(c[EH_MOUTH_PRESS_L]) + eh_saturate(c[EH_MOUTH_PRESS_L + 1]));
    r.cheekPuff = eh_saturate(c[EH_CHEEK_PUFF]);
    r.tongue = eh_saturate(c[EH_TONGUE_OUT]);

    for (int s = 0; s < 2; s++) {
        float stretch = eh_saturate(c[EH_MOUTH_STRETCH_L + s]);
        float smile = eh_saturate(c[EH_MOUTH_SMILE_L + s]);
        r.mouthHalfWidth[s] = r.mouthBaseWidth * (1.0 + 0.28 * stretch + 0.16 * smile - 0.40 * r.pucker - 0.22 * r.funnel);
    }

    float upperUp = 0.5 * (eh_saturate(c[EH_MOUTH_UPPER_UP_L]) + eh_saturate(c[EH_MOUTH_UPPER_UP_L + 1]));
    float lowerDown = 0.5 * (eh_saturate(c[EH_MOUTH_LOWER_DOWN_L]) + eh_saturate(c[EH_MOUTH_LOWER_DOWN_L + 1]));
    float shift = 0.07 * (eh_saturate(c[EH_MOUTH_RIGHT]) - eh_saturate(c[EH_MOUTH_LEFT])) + 0.6 * r.jawShift.x;
    float protrude = 0.06 * r.pucker + 0.03 * r.funnel;
    float3 m = r.mouth + float3(shift, 0.0, 0.0);
    r.upperLip = m + float3(0.0,
                            0.036 + 0.030 * upperUp + 0.015 * eh_saturate(c[EH_MOUTH_SHRUG_UPPER]) - 0.006 * r.press,
                            0.010 + protrude);
    float3 lowerRest = m + float3(0.0,
                                  -0.044 - 0.035 * lowerDown + 0.015 * eh_saturate(c[EH_MOUTH_SHRUG_LOWER]) + 0.008 * r.press,
                                  protrude);
    r.lowerLip = eh_jawRotate(lowerRest, r.lowerLipAngle) + r.jawShift;
    return r;
}

// MARK: - SDF primitives

static inline float eh_sphere(float3 p, float r) { return length(p) - r; }

static inline float eh_ellipsoid(float3 p, float3 r) {
    float k0 = length(p / r);
    float k1 = length(p / (r * r));
    return k0 * (k0 - 1.0) / max(k1, 1e-6);
}

static inline float eh_capsule(float3 p, float3 a, float3 b, float r) {
    float3 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h) - r;
}

static inline float eh_roundBox(float3 p, float3 b, float r) {
    float3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0) - r;
}

static inline float eh_smin(float a, float b, float k) {
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

static inline float eh_smax(float a, float b, float k) { return -eh_smin(-a, -b, k); }

static inline float2 eh_rot(float2 v, float a) {
    float c = cos(a), s = sin(a);
    return float2(c * v.x - s * v.y, s * v.x + c * v.y);
}

// MARK: - Anatomy

static float eh_skull(float3 q, thread const EHRig& r) {
    float d = eh_ellipsoid(q - float3(0.0, 0.28, -0.08), float3(0.80, 0.86, 0.90));
    d = eh_smin(d, eh_ellipsoid(q - float3(0.0, 0.30, 0.36), float3(0.62, 0.32, 0.44)), 0.20);  // brow / forehead
    d = eh_smin(d, eh_ellipsoid(q - float3(0.0, -0.12, 0.30), float3(0.66 * r.cheekWidth, 0.42, 0.52)), 0.24); // midface
    return d;
}

// `j` is the point in the jaw's rest frame (jaw opening and shift undone).
static float eh_jaw(float3 j, thread const EHRig& r) {
    float cs = r.chinShift, jw = r.jawWidth;
    float d = eh_ellipsoid(j - float3(0.0, -0.56 - 0.6 * cs, 0.18), float3(0.52 * jw, 0.40 + 0.5 * cs, 0.56));
    d = eh_smin(d, eh_ellipsoid(j - float3(0.0, -0.60 - 0.4 * cs, -0.05), float3(0.55 * jw, 0.34, 0.55)), 0.18); // jawline
    d = eh_smin(d, eh_ellipsoid(j - float3(0.0, -0.85 - cs, 0.42), float3(0.22, 0.17, 0.20)), 0.20);           // chin
    return d;
}

static float eh_nose(float3 q, thread const EHRig& r) {
    float sn = 0.5 * (r.sneer[0] + r.sneer[1]);
    float tip = r.noseTipY, nw = r.noseWidth;
    float d = eh_capsule(q, float3(0.0, 0.15, 0.78), float3(0.0, tip + 0.04, 0.95), 0.068);
    d = eh_smin(d, eh_sphere(q - float3(0.0, tip + 0.012 * sn, 0.960), 0.092), 0.07);
    for (int s = 0; s < 2; s++) {
        float sx = s == 0 ? -1.0 : 1.0;
        float3 ala = float3(sx * (0.094 * nw + 0.014 * r.sneer[s]), tip - 0.062 + 0.030 * r.sneer[s], 0.855);
        d = eh_smin(d, eh_ellipsoid(q - ala, float3(0.064 * nw, 0.052, 0.064)), 0.075);
        d = eh_smax(d, -eh_ellipsoid(q - float3(sx * 0.050 * nw, tip - 0.110, 0.895), float3(0.028 * nw, 0.015, 0.036)), 0.02);
    }
    return d;
}

static float eh_ears(float3 q) {
    float d = 1e3;
    for (int s = 0; s < 2; s++) {
        float sx = s == 0 ? -1.0 : 1.0;
        float3 e = q - float3(sx * 0.80, -0.02, -0.10);
        e.xz = eh_rot(e.xz, sx * 0.35);
        float ear = eh_ellipsoid(e, float3(0.085, 0.21, 0.14));
        ear = eh_smax(ear, -eh_sphere(e - float3(sx * 0.065, -0.01, 0.03), 0.072), 0.025);
        d = min(d, ear);
    }
    return d;
}

static inline float3 eh_eyeCenter(float sx) { return float3(sx * EH_EYE_X, EH_EYE_Y, EH_EYE_Z); }

// Elevation angles (radians, looking along +z) of the upper and lower lid margins. Closing =
// the two lines crossing. Shared by the lid geometry and the lash-line shading.
static float2 eh_lidAngles(thread const EHRig& r, int s) {
    float open = 1.0 - r.blink[s];
    float upper = mix(0.37, -0.34, r.blink[s]) + 0.16 * r.wide[s] * open - 0.08 * r.squint[s] * open;
    float lower = mix(-0.50, -0.28, r.blink[s]) + 0.22 * r.squint[s] * open + 0.10 * r.cheekLift[s] * open;
    return float2(upper, lower);
}

// Eye-local frame with the canthal tilt applied (outer corner slightly up).
static inline float3 eh_eyeLocal(float3 q, float sx) {
    float3 p = q - eh_eyeCenter(sx);
    p.xy = eh_rot(p.xy, -sx * 0.10);
    return p;
}

// Eyelid = thin shell around the eyeball, kept only where the elevation angle is above the
// upper-lid line or below the lower-lid line.
static float eh_lid(float3 q, float sx, int s, thread const EHRig& r) {
    float3 p = eh_eyeLocal(q, sx);
    float lidR = 0.176 * r.eyeScale;
    float shell = abs(length(p) - lidR) - 0.012;
    float2 lid = eh_lidAngles(r, s);
    float e = atan2(p.y, max(p.z, 1e-4));
    float region = min(lid.x - e, e - lid.y) * lidR;
    return eh_smax(shell, region, 0.012);
}

static float eh_brow(float3 q, float sx, int s, thread const EHRig& r) {
    float pull = r.browPull[s], by = r.browLift;
    float3 a = float3(sx * (0.100 - 0.025 * pull), by + 0.300 + 0.075 * r.browInner[s] - 0.045 * pull, 0.843);
    float3 b = float3(sx * 0.280, by + 0.345 + 0.040 * (r.browInner[s] + r.browOuter[s]), 0.798);
    float3 c = float3(sx * 0.460, by + 0.300 + 0.070 * r.browOuter[s] - 0.015 * pull, 0.708);
    float d = eh_capsule(q, a, b, 0.036);
    return eh_smin(d, eh_capsule(q, b, c, 0.027), 0.02);
}

static float eh_hair(float3 q, thread const EHRig& r, thread float& groove) {
    float shell = eh_ellipsoid(q - float3(0.0, 0.35, -0.09), float3(0.87 * r.hairWidth, 0.94 * r.hairHeight, 0.98));
    // Hairline: high at the front (forehead shows), low at the back; ears stay clear.
    float t = smoothstep(-0.30, 0.50, q.z);
    float hl = mix(-0.55, r.hairlineY + 0.25 * q.x * q.x, t);
    // Wide transitions: this raises the hairline by ~0.25 around the ears, and a short ramp in z
    // made the cut steep enough to overstep (stipple just behind the ear).
    float earZone = smoothstep(0.55, 0.75, abs(q.x)) * (1.0 - smoothstep(0.10, 0.60, abs(q.z + 0.08)));
    hl = mix(hl, max(hl, 0.24), earZone);
    // The cut is a height field whose slope steepens at the sides; scaling it keeps the distance
    // conservative there (oversized steps stipple thin hair at grazing angles).
    float d = eh_smax(shell, (hl - q.y) * 0.5, 0.06);
    float az = atan2(q.x, q.z);
    // atan2 is discontinuous at the crown; fade every azimuth-driven detail out there — and below
    // ear level, where the strands are seen edge-on behind the ears and alias into stipple.
    float crownFade = smoothstep(0.10, 0.55, length(q.xz)) * smoothstep(-0.15, 0.25, q.y);
    // Low-frequency clumping breaks the helmet silhouette into locks.
    d -= 0.028 * sin(az * 4.0 + 1.3) * sin(q.y * 3.5 + az * 2.0) * crownFade;
    // Sculpted strands running from the crown down.
    groove = 0.5 + 0.5 * sin(az * 22.0 + q.y * 5.0 + 1.6 * sin(az * 7.0));
    groove = mix(0.5, groove, crownFade);
    d -= 0.012 * groove;
    // Swept fringe built from three overlapping locks.
    float3 f0 = q - float3(-0.02, 0.70, 0.56);  f0.xy = eh_rot(f0.xy, -0.30);
    float3 f1 = q - float3(0.26, 0.62, 0.54);   f1.xy = eh_rot(f1.xy, -0.45);
    float3 f2 = q - float3(0.50, 0.50, 0.40);   f2.xy = eh_rot(f2.xy, -0.75);
    if (r.fringe > 0.5) {
        float fringe = min(eh_ellipsoid(f0, float3(0.32, 0.12, 0.24)),
                           min(eh_ellipsoid(f1, float3(0.28, 0.12, 0.24)), eh_ellipsoid(f2, float3(0.22, 0.11, 0.22))));
        d = eh_smin(d, fringe, 0.08);
    }
    return d;
}

// `shape`: +1 upper lip (cupid's bow on the top edge), -1 lower lip (fuller centre), 0 cavity.
static float eh_lip(float3 q, float3 c, float2 hw2, float hy, float hz, float shape, thread const EHRig& r) {
    float3 p = q - c;
    float hw = p.x < 0.0 ? hw2.x : hw2.y;
    float u = clamp(p.x / hw, -1.2, 1.2);
    p.y -= (p.x < 0.0 ? r.corner[0] : r.corner[1]) * u * u;
    p.z += 0.90 * p.x * p.x;   // wrap around the face curvature
    float taper = max(1.0 - 0.70 * u * u, 0.18);
    float ax = abs(p.x);
    if (shape > 0.5 && p.y > 0.0) {
        taper *= 1.0 + 0.30 * exp(-pow((ax - 0.045) / 0.032, 2.0)) - 0.22 * exp(-pow(p.x / 0.022, 2.0));
    } else if (shape < -0.5) {
        taper *= 1.0 + 0.18 * exp(-pow(p.x / 0.085, 2.0));
    }
    float d = eh_ellipsoid(p, float3(hw, hy * taper, hz * max(1.0 - 0.3 * u * u, 0.4)));
    // eh_ellipsoid underestimates badly for very flat shapes away from the centre, which would
    // carve a hairline slot across the cheeks; clamp the influence to the mouth's own width.
    return max(d, abs(p.x) - hw);
}

// Closest surface plus the runner-up, so shading can blend materials across the ~1px band where
// two surfaces meet (hairline, brows, lid margins) instead of switching hard and aliasing.
struct EHHit {
    float d;
    float mat;
    float aux;
    float aux2;
    float d2;
    float mat2;
    float auxB;
    float aux2B;
    float2 rest;   // head-local (x, y) of the skin point with jaw motion undone — portrait UV source
};

static inline void eh_consider(thread EHHit& h, float d, float mat, float aux, float aux2) {
    if (d < h.d) {
        if (mat != h.mat) { h.d2 = h.d; h.mat2 = h.mat; h.auxB = h.aux; h.aux2B = h.aux2; }
        h.d = d; h.mat = mat; h.aux = aux; h.aux2 = aux2;
    } else if (d < h.d2 && mat != h.mat) {
        h.d2 = d; h.mat2 = mat; h.auxB = aux; h.aux2B = aux2;
    }
}

static inline float2 eh_portraitUV(float2 rest, constant ExpressiveHeadUniforms& u) {
    float3 h = float3(rest, 1.0);
    return float2(dot(u.uvRowU.xyz, h), dot(u.uvRowV.xyz, h));
}

// Painted brows follow the brow coefficients: shift the texture lookup by the same lift the
// capsule brows use (inner / outer ends, pull-down), weighted to a band around the brow line.
static float2 eh_browWarp(float2 rest, thread const EHRig& r) {
    int s = rest.x < 0.0 ? 0 : 1;
    float t = eh_saturate((abs(rest.x) - 0.10) / 0.36);
    float pull = r.browPull[s];
    float lift = mix(0.075 * r.browInner[s] - 0.045 * pull, 0.070 * r.browOuter[s] - 0.015 * pull, t);
    float browY = r.browLift + mix(0.30, 0.30, t) + 0.045 * (1.0 - abs(2.0 * t - 1.0));
    float band = exp(-pow((rest.y - browY) / 0.09, 2.0)) * (1.0 - smoothstep(0.50, 0.62, abs(rest.x)));
    return float2(rest.x, rest.y - lift * band);
}

// Full scene in head-local space (everything except the neck).
static EHHit eh_mapHead(float3 q, thread const EHRig& r, constant ExpressiveHeadUniforms& u,
                        texture2d<float> reliefTex) {
    EHHit h;

    // Skin: skull + jaw + cheeks + nose + ears, sockets carved, lids added. The rest coordinate
    // blends between the skull frame and the jaw's rest frame by whichever dominates here.
    float3 j = eh_jawRotate(q - r.jawShift, -r.jawAngle);
    float dSkull = eh_skull(q, r), dJaw = eh_jaw(j, r);
    float skin = eh_smin(dSkull, dJaw, 0.22);
    float2 rest = mix(q.xy, j.xy, eh_saturate(0.5 + (dSkull - dJaw) / 0.22));
    for (int s = 0; s < 2; s++) {
        float sx = s == 0 ? -1.0 : 1.0;
        float3 cc = float3(sx * 0.355, -0.25 + 0.06 * r.cheekLift[s], 0.50 + 0.07 * r.cheekPuff);
        skin = eh_smin(skin, eh_ellipsoid(q - cc, float3(0.20, 0.15, 0.14) + 0.06 * r.cheekPuff), 0.22);
    }
    // Muzzle: the orbicularis mound the lips sit on; follows the jaw halfway down.
    float3 muzzle = eh_jawRotate(r.mouth, 0.5 * r.jawAngle) + float3(0.0, -0.02, -0.20);
    skin = eh_smin(skin, eh_ellipsoid(q - muzzle, float3(0.25, 0.18, 0.17)), 0.14);
    skin = eh_smin(skin, eh_nose(q, r), 0.07);
    for (int s = 0; s < 2; s++) {
        float sx = s == 0 ? -1.0 : 1.0;
        float lift = r.cheekLift[s];
        if (lift > 0.01) {
            float crease = eh_capsule(q, float3(sx * 0.135 * r.noseWidth, r.noseTipY - 0.08, 0.80),
                                      float3(sx * (r.mouthBaseWidth + 0.05), r.mouth.y + 0.04 * lift, 0.71), 0.016 * lift);
            skin = eh_smax(skin, -crease, 0.04);
        }
    }
    // Person-specific relief from the portrait's depth map (band-passed, face only). Faded out
    // around the eye openings so it can't creep over the eyes; brows ride on it below.
    float relief = 0.0;
    if (u.likeness.y > 0.0) {
        float front = smoothstep(0.20, 0.50, q.z);
        float sxe = q.x < 0.0 ? -1.0 : 1.0;
        float eyeDist = length((q.xy - float2(sxe * EH_EYE_X, EH_EYE_Y)) / (float2(0.21, 0.13) * r.eyeScale));
        float w = front * smoothstep(0.95, 1.35, eyeDist);
        if (w > 0.0) {
            relief = reliefTex.sample(eh_samp, eh_portraitUV(rest, u)).r * u.likeness.y * w;
            skin -= relief;
        }
    }
    skin = eh_smin(skin, eh_ears(q), 0.05);
    for (int s = 0; s < 2; s++) {
        float sx = s == 0 ? -1.0 : 1.0;
        skin = eh_smax(skin, -eh_ellipsoid(q - float3(sx * 0.30, 0.10, 0.66), float3(0.20, 0.13, 0.15) * r.eyeScale), 0.12);
        skin = eh_smin(skin, eh_lid(q, sx, s, r), 0.03);
    }

    // Mouth: only evaluated near the mouth — far away it can't change the distance.
    float lipW = 0.0, interiorW = 0.0;
    float teeth = 1e3, tongue = 1e3;
    float mouthBound = length(q - r.mouth) - 0.55;
    if (mouthBound < skin + 0.05) {
        float2 w = r.mouthHalfWidth;
        float press = 1.0 - 0.25 * r.press;
        float upper = eh_lip(q, r.upperLip, w, r.lipH.x * (1.0 - 0.5 * r.rollUpper) * press, 0.050, 1.0, r);
        float lower = eh_lip(q, r.lowerLip, w * 0.92, r.lipH.y * (1.0 - 0.5 * r.rollLower) * press, 0.055, -1.0, r);
        float lips = min(upper, lower);
        for (int s = 0; s < 2; s++) {
            float sx = s == 0 ? -1.0 : 1.0;
            float3 cornerPt = float3(r.mouth.x + sx * (w[s] + 0.03), 0.5 * (r.upperLip.y + r.lowerLip.y) + r.corner[s], 0.70);
            skin = eh_smax(skin, -eh_sphere(q - cornerPt, 0.018 * r.dimple[s]), 0.01);
        }
        float withLips = eh_smin(skin, lips, 0.035);
        lipW = eh_saturate(0.5 + (skin - lips) / 0.03);

        float halfH = max(0.5 * (r.upperLip.y - r.lowerLip.y) - 0.034, 0.006);
        float3 mid = 0.5 * (r.upperLip + r.lowerLip) + float3(0.0, 0.0, -0.075);
        float cavity = eh_lip(q, mid, w * 0.90, halfH, 0.17, 0.0, r);
        skin = eh_smax(withLips, -cavity, 0.02);
        interiorW = eh_saturate(0.5 + (-cavity - withLips) / 0.02);

        float3 ut = q - (r.upperLip + float3(0.0, -0.032, -0.064));
        ut.z += 1.6 * ut.x * ut.x;
        float3 lt = q - (r.lowerLip + float3(0.0, 0.034, -0.066));
        lt.z += 1.6 * lt.x * lt.x;
        float wm = 0.5 * (w.x + w.y);
        teeth = min(eh_roundBox(ut, float3(wm * 0.70, 0.024, 0.022), 0.010),
                    eh_roundBox(lt, float3(wm * 0.66, 0.022, 0.020), 0.010));
        float3 tc = r.lowerLip + float3(0.0, 0.022 + 0.02 * r.tongue, -0.13 + 0.18 * r.tongue);
        tongue = eh_ellipsoid(q - tc, float3(wm * 0.55, 0.035, 0.10 + 0.05 * r.tongue));
    }

    h.d = skin; h.mat = EH_MAT_SKIN; h.aux = lipW; h.aux2 = interiorW;
    h.d2 = 1e3; h.mat2 = EH_MAT_SKIN; h.auxB = 0.0; h.aux2B = 0.0;
    h.rest = rest;

    float eyeL = eh_sphere(q - eh_eyeCenter(-1.0), r.eyeR);
    float eyeR = eh_sphere(q - eh_eyeCenter(1.0), r.eyeR);
    eh_consider(h, min(eyeL, eyeR), EH_MAT_EYE, eyeL < eyeR ? 0.0 : 1.0, 0.0);
    eh_consider(h, teeth, EH_MAT_TEETH, 0.0, 0.0);
    eh_consider(h, tongue, EH_MAT_TONGUE, 0.0, 0.0);
    // With a likeness the portrait's own brows are painted (and moved — see eh_browWarp), so the
    // generic capsule brows are dropped.
    if (u.likeness.x < 0.5) {
        eh_consider(h, min(eh_brow(q, -1.0, 0, r), eh_brow(q, 1.0, 1, r)) - relief, EH_MAT_HAIR, 0.5, 1.0);
    }
    float groove = 0.0;
    float hair = eh_hair(q, r, groove);
    eh_consider(h, hair, EH_MAT_HAIR, groove, 0.0);
    return h;
}

static inline float3 eh_toHead(float3 p, constant ExpressiveHeadUniforms& u) {
    // q = Rᵀ p, with R supplied as rows.
    return u.rotRow0.xyz * p.x + u.rotRow1.xyz * p.y + u.rotRow2.xyz * p.z;
}

static EHHit eh_map(float3 p, thread const EHRig& r, constant ExpressiveHeadUniforms& u,
                    texture2d<float> reliefTex) {
    float3 q = eh_toHead(p, u);
    float neck = eh_capsule(p, float3(0.0, -0.55, -0.18), float3(0.0, -2.40, -0.30), 0.37);
    // Every part of the head (hair, ears, nose, chin at max chinShift) lies inside this sphere,
    // so outside it the head distance is ≥ `bound`. Most raymarch steps happen out here; skip the
    // full scene unless the neck blend (smin, k = 0.10) could be affected by the true head.
    float bound = length(q - float3(0.0, 0.06, 0.0)) - r.boundR;
    EHHit h;
    h.mat = EH_MAT_SKIN; h.aux = 0.0; h.aux2 = 0.0;
    h.d2 = 1e3; h.mat2 = EH_MAT_SKIN; h.auxB = 0.0; h.aux2B = 0.0; h.rest = q.xy;
    if (bound > 0.06 && neck + 0.10 <= bound) {
        h.d = neck;                 // head is ≥ 0.10 farther: no blend, the neck is exact
        return h;
    }
    if (bound > 0.06 && neck >= bound) {
        h.d = bound - 0.025;        // smin lower bound; > eps, so it can never register a hit
        return h;
    }
    h = eh_mapHead(q, r, u, reliefTex);
    if (neck < h.d + 0.10) {
        float blended = eh_smin(h.d, neck, 0.10);
        if (neck < h.d) {
            if (h.mat != EH_MAT_SKIN) { h.d2 = h.d; h.mat2 = h.mat; h.auxB = h.aux; h.aux2B = h.aux2; }
            h.mat = EH_MAT_SKIN; h.aux = 0.0; h.aux2 = 0.0;
        }
        h.d = blended;
    }
    return h;
}

// Occlusion queries (soft shadow, AO) march *away* from the surface. Once outside the head's
// bounding sphere a straight ray can't re-enter it, so only the neck can occlude there — using
// eh_map's conservative lower bound instead would read as a phantom occluder and band the shading.
static float eh_occluderDistance(float3 p, thread const EHRig& r, constant ExpressiveHeadUniforms& u,
                                 texture2d<float> reliefTex) {
    float bound = length(eh_toHead(p, u) - float3(0.0, 0.06, 0.0)) - r.boundR;
    if (bound > 0.06) {
        return eh_capsule(p, float3(0.0, -0.55, -0.18), float3(0.0, -2.40, -0.30), 0.37);
    }
    return eh_map(p, r, u, reliefTex).d;
}

static float3 eh_normal(float3 p, thread const EHRig& r, constant ExpressiveHeadUniforms& u,
                        texture2d<float> reliefTex) {
    const float e = 0.0015;
    const float2 k = float2(1.0, -1.0);
    return normalize(k.xyy * eh_map(p + k.xyy * e, r, u, reliefTex).d +
                     k.yyx * eh_map(p + k.yyx * e, r, u, reliefTex).d +
                     k.yxy * eh_map(p + k.yxy * e, r, u, reliefTex).d +
                     k.xxx * eh_map(p + k.xxx * e, r, u, reliefTex).d);
}

static float eh_softShadow(float3 ro, float3 rd, thread const EHRig& r, constant ExpressiveHeadUniforms& u,
                           texture2d<float> reliefTex) {
    float res = 1.0;
    float t = 0.045;   // clear of the surface's own displacement detail (grazing hair shadow acne)
    for (int i = 0; i < 20 && t < 2.0; i++) {
        float h = eh_occluderDistance(ro + rd * t, r, u, reliefTex);
        res = min(res, 10.0 * h / t);
        if (res < 0.02) break;
        t += clamp(h, 0.02, 0.20);
    }
    return eh_saturate(res);
}

static float eh_ao(float3 p, float3 n, thread const EHRig& r, constant ExpressiveHeadUniforms& u,
                  texture2d<float> reliefTex) {
    float occ = 0.0, sca = 1.0;
    for (int i = 0; i < 5; i++) {
        float h = 0.01 + 0.05 * float(i);
        occ += (h - eh_occluderDistance(p + n * h, r, u, reliefTex)) * sca;
        sca *= 0.75;
    }
    return eh_saturate(1.0 - 2.2 * occ);
}

static float eh_hash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

// Eye surface colour: sclera / iris / pupil from the angle between the surface point and the
// gaze axis. `n` is camera space, `q` head-local.
static float3 eh_eyeColor(float3 q, float side, thread const EHRig& r, constant ExpressiveHeadUniforms& u,
                          thread float& irisMask) {
    float sx = side < 0.5 ? -1.0 : 1.0;
    float3 pe = normalize(q - eh_eyeCenter(sx));
    float yaw = r.gaze.x * 0.42 - sx * 0.03;   // slight convergence
    float pitch = r.gaze.y * 0.32;
    float3 axis = normalize(float3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)));
    float ang = acos(clamp(dot(pe, axis), -1.0, 1.0));

    const float irisR = 0.50, pupilR = 0.19;
    float3 t1 = normalize(cross(axis, float3(0.0, 1.0, 0.0)));
    float3 t2 = cross(axis, t1);
    float polar = atan2(dot(pe, t2), dot(pe, t1));

    float3 sclera = mix(float3(0.88, 0.86, 0.83), float3(0.80, 0.62, 0.60), smoothstep(0.9, 1.6, ang));
    float3 iris = u.irisColor.rgb;
    float fibers = 0.80 + 0.20 * sin(polar * 34.0 + 3.0 * sin(polar * 7.0)) + 0.10 * (eh_hash(float2(floor(polar * 40.0), 3.0)) - 0.5);
    iris *= fibers;
    iris = mix(iris * 1.45 + float3(0.06, 0.04, 0.0), iris, smoothstep(pupilR, pupilR + 0.12, ang)); // collarette
    iris *= mix(1.0, 0.35, smoothstep(irisR - 0.10, irisR, ang));                               // limbal ring
    irisMask = 1.0 - smoothstep(irisR - 0.015, irisR + 0.015, ang);
    float pupil = 1.0 - smoothstep(pupilR - 0.015, pupilR + 0.015, ang);
    float3 col = mix(sclera, iris, irisMask);
    return mix(col, float3(0.01, 0.01, 0.012), pupil);
}

// Surface response for one material at a hit. Two of these blend across material edges.
struct EHSurface {
    float3 albedo;
    float wrap;       // diffuse wrap (skin scatter)
    float specPow;
    float specAmt;
    float sss;        // terminator reddening weight
    float hairSpec;   // Kajiya-Kay weight
    float catchLight; // cornea catch-light weight
};

static EHSurface eh_surface(float mat, float aux, float aux2, float3 q, float2 rest, float3 nLocal,
                            thread const EHRig& r, constant ExpressiveHeadUniforms& u,
                            texture2d<float> albedoTex, texture2d<float> reliefTex) {
    EHSurface m;
    m.wrap = 0.0; m.specPow = 30.0; m.specAmt = 0.15; m.sss = 0.0; m.hairSpec = 0.0; m.catchLight = 0.0;
    if (mat == EH_MAT_SKIN) {
        float3 albedo = u.skinColor.rgb;
        // Warmth where blood is close to the surface: cheeks, nose tip.
        float2 cl = q.xy - float2(-0.36, -0.25), cr = q.xy - float2(0.36, -0.25);
        float3 nt = q - float3(0.0, -0.17, 0.96);
        float blush = exp(-dot(cl, cl) * 18.0) + exp(-dot(cr, cr) * 18.0) + 0.6 * exp(-dot(nt, nt) * 60.0);
        // The portrait carries its own colouring; procedural blush only for the generic head.
        albedo = mix(albedo, albedo * float3(1.10, 0.80, 0.78), eh_saturate(blush) * 0.45 * (1.0 - u.likeness.x));
        albedo = mix(albedo, u.lipColor.rgb, aux);
        // Likeness: the de-lit portrait, where it shows skin or lips (alpha), faces the camera,
        // and isn't the eye opening (lids must stay skin when they close over a painted eye).
        if (u.likeness.x > 0.5) {
            float2 uv = eh_portraitUV(eh_browWarp(rest, r), u);
            float inside = step(0.0, uv.x) * step(uv.x, 1.0) * step(0.0, uv.y) * step(uv.y, 1.0);
            float4 photo = albedoTex.sample(eh_samp, uv);
            float facing = smoothstep(0.15, 0.50, nLocal.z);
            float sx = q.x < 0.0 ? -1.0 : 1.0;
            float eyeDist = length((q.xy - float2(sx * EH_EYE_X, EH_EYE_Y)) / (float2(0.21, 0.13) * r.eyeScale));
            float cov = photo.a * inside * facing * smoothstep(0.95, 1.35, eyeDist);
            albedo = mix(albedo, pow(max(photo.rgb, 0.0), float3(2.2)), cov);
        }
        albedo = mix(albedo, float3(0.16, 0.035, 0.04), aux2);
        // Lash line along the lid margins — dark upper, softer lower; when the lids meet it
        // becomes the closed-eye seam.
        int s = q.x < 0.0 ? 0 : 1;
        float3 pl = eh_eyeLocal(q, s == 0 ? -1.0 : 1.0);
        float rl = length(pl);
        float es = r.eyeScale;
        if (rl < 0.22 * es) {
            float2 lid = eh_lidAngles(r, s);
            float e = atan2(pl.y, max(pl.z, 1e-4));
            float across = 1.0 - smoothstep(0.70, 1.05, abs(atan2(pl.x, max(pl.z, 1e-4))));
            float onLid = 1.0 - smoothstep(0.190 * es, 0.215 * es, rl);
            float upperLash = (1.0 - smoothstep(0.015, 0.075, abs(e - lid.x))) * onLid * across;
            float lowerLash = (1.0 - smoothstep(0.010, 0.045, abs(e - lid.y))) * onLid * across * 0.55;
            albedo = mix(albedo, float3(0.035, 0.022, 0.020), eh_saturate(max(upperLash, lowerLash)));
        }
        m.albedo = albedo;
        m.wrap = 0.45; m.sss = 1.0 - aux2;
        m.specPow = mix(22.0, 70.0, aux); m.specAmt = mix(0.18, 0.35, aux) * (1.0 - aux2);
    } else if (mat == EH_MAT_EYE) {
        float irisMask = 0.0;
        m.albedo = eh_eyeColor(q, aux, r, u, irisMask);
        m.specPow = 600.0; m.specAmt = 2.5; m.wrap = 0.2; m.catchLight = 1.0;
    } else if (mat == EH_MAT_HAIR) {
        if (aux2 > 0.5) {
            // Brow: fine strokes angled up-and-out from the bridge of the nose.
            float strokes = 0.78 + 0.22 * sin(abs(q.x) * 150.0 + q.y * 70.0);
            m.albedo = u.hairColor.rgb * 0.80 * strokes;
        } else {
            m.albedo = u.hairColor.rgb * (0.62 + 0.38 * aux);
            m.hairSpec = 0.5 + 0.5 * aux;
            // The portrait's own hair colour where it shows hair and the strand faces the camera.
            if (u.likeness.z > 0.5) {
                float2 uv = eh_portraitUV(q.xy, u);
                float cov = reliefTex.sample(eh_samp, uv).g * smoothstep(0.20, 0.55, nLocal.z);
                float3 photo = pow(max(albedoTex.sample(eh_samp, uv).rgb, 0.0), float3(2.2));
                m.albedo = mix(m.albedo, photo * (0.80 + 0.40 * aux), cov);
            }
        }
        m.specPow = 0.0; m.specAmt = 0.0; m.wrap = 0.25;
    } else if (mat == EH_MAT_TEETH) {
        m.albedo = float3(0.86, 0.83, 0.75);
        m.specPow = 80.0; m.specAmt = 0.4;
    } else {
        m.albedo = float3(0.70, 0.27, 0.30);
        m.specPow = 50.0; m.specAmt = 0.3; m.wrap = 0.3;
    }
    return m;
}

static float3 eh_shade(float3 p, float3 rd, EHHit hit, thread const EHRig& r, constant ExpressiveHeadUniforms& u,
                       texture2d<float> albedoTex, texture2d<float> reliefTex) {
    float3 n = eh_normal(p, r, u, reliefTex);
    float3 v = -rd;
    float3 L = normalize(u.keyLightDir.xyz);
    float3 q = eh_toHead(p, u);
    float3 nLocal = eh_toHead(n, u);

    EHSurface m = eh_surface(hit.mat, hit.aux, hit.aux2, q, hit.rest, nLocal, r, u, albedoTex, reliefTex);
    // Material-edge antialiasing: within ~1.5px of the runner-up surface, blend toward it
    // (50/50 exactly on the junction).
    float edge = (1.0 - smoothstep(0.0, 1.5 * u.params.y, hit.d2 - hit.d)) * 0.5;
    if (edge > 0.001 && hit.mat2 != hit.mat) {
        EHSurface m2 = eh_surface(hit.mat2, hit.auxB, hit.aux2B, q, hit.rest, nLocal, r, u, albedoTex, reliefTex);
        m.albedo = mix(m.albedo, m2.albedo, edge);
        m.wrap = mix(m.wrap, m2.wrap, edge);
        m.specPow = mix(m.specPow, m2.specPow, edge);
        m.specAmt = mix(m.specAmt, m2.specAmt, edge);
        m.sss = mix(m.sss, m2.sss, edge);
        m.hairSpec = mix(m.hairSpec, m2.hairSpec, edge);
        m.catchLight = mix(m.catchLight, m2.catchLight, edge);
    }

    float ndl = dot(n, L);
    float diff = eh_saturate((ndl + m.wrap) / (1.0 + m.wrap));
    float shadow = diff > 0.0 ? eh_softShadow(p + n * 0.01, L, r, u, reliefTex) : 0.0;
    float ao = eh_ao(p, n, r, u, reliefTex);

    float3 keyCol = float3(1.00, 0.94, 0.86) * 1.35;
    float3 fillDir = normalize(float3(0.65, 0.05, 0.60));
    float3 fillCol = float3(0.42, 0.52, 0.72) * 0.40;
    float3 rimDir = normalize(float3(0.45, 0.35, -0.80));
    float3 rimCol = float3(0.85, 0.92, 1.00) * 0.90;
    float3 sky = float3(0.34, 0.39, 0.47), ground = float3(0.20, 0.16, 0.14);

    float3 col = m.albedo * keyCol * diff * mix(0.25, 1.0, shadow);
    // Subsurface: light bleeding past the terminator reads red in skin.
    float term = smoothstep(-0.25, 0.20, ndl) * (1.0 - smoothstep(0.20, 0.75, ndl));
    col += m.albedo * float3(1.0, 0.32, 0.22) * term * 0.30 * m.sss;
    col += m.albedo * fillCol * eh_saturate(dot(n, fillDir) * 0.5 + 0.5);
    col += m.albedo * mix(ground, sky, n.y * 0.5 + 0.5) * 0.55 * ao;
    float rim = pow(1.0 - eh_saturate(dot(n, v)), 3.0) * eh_saturate(dot(n, rimDir) + 0.6);
    col += rimCol * rim * 0.35 * ao;

    float3 hv = normalize(L + v);
    float fres = 0.04 + 0.96 * pow(1.0 - eh_saturate(dot(n, v)), 5.0);
    if (m.hairSpec > 0.0) {
        // Kajiya-Kay: highlight across strands running crown → down.
        float3 tng = normalize(float3(0.0, -1.0, 0.0) - n * dot(n, float3(0.0, -1.0, 0.0)) + float3(1e-4));
        float th = dot(tng, hv);
        float sinTH = sqrt(max(1.0 - th * th, 0.0));
        float primary = pow(sinTH, 90.0) * 0.30;
        float secondary = pow(sinTH, 24.0) * 0.12;
        col += (keyCol * primary + u.hairColor.rgb * keyCol * secondary * 2.0) * shadow * m.hairSpec;
    }
    if (m.specAmt > 0.0) {
        float spec = pow(eh_saturate(dot(n, hv)), max(m.specPow, 1.0)) * m.specAmt * (0.25 + fres);
        col += keyCol * spec * shadow;
    }
    if (m.catchLight > 0.0) {
        // Catch-light from a soft box up-left, independent of the key's shadowing.
        float catchL = pow(eh_saturate(dot(reflect(rd, n), normalize(float3(-0.35, 0.45, 0.82)))), 900.0);
        col += float3(1.0) * catchL * 1.6 * m.catchLight;
    }
    return col * mix(0.55, 1.0, ao);
}

// MARK: - Entry points

struct ExpressiveHeadVOut {
    float4 position [[position]];
    float2 local;     // head-local camera-plane coordinates of this fragment
};

vertex ExpressiveHeadVOut expressive_head_vertex(uint vid [[vertex_id]],
                                                 constant ExpressiveHeadUniforms& u [[buffer(0)]]) {
    float2 corners[4] = { float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0), float2(1.0, 1.0) };
    float2 c = corners[vid];
    ExpressiveHeadVOut out;
    out.position = float4(u.rectNDC.x + c.x * u.rectNDC.z, u.rectNDC.y + c.y * u.rectNDC.w, 0.0, 1.0);
    out.local = float2(mix(u.localRect.x, u.localRect.z, c.x), mix(u.localRect.y, u.localRect.w, c.y));
    return out;
}

fragment float4 expressive_head_fragment(ExpressiveHeadVOut in [[stage_in]],
                                         constant ExpressiveHeadUniforms& u [[buffer(0)]],
                                         constant float* coefs [[buffer(1)]],
                                         texture2d<float> albedoTex [[texture(0)]],
                                         texture2d<float> reliefTex [[texture(1)]]) {
    if (abs(in.local.x) > 1.25) { return float4(0.0); }
    EHRig r = eh_makeRig(coefs, u);

    float upp = u.params.y;                      // head-local units per pixel
    float eps = max(0.35 * upp, 0.0004);
    float aa = 1.25 * upp;
    float3 ro = float3(in.local, 1.40);
    float3 rd = float3(0.0, 0.0, -1.0);
    int maxSteps = int(u.params.z);

    float t = 0.0;
    float minD = 1e3, tMin = 0.0;
    bool hitSurface = false;
    EHHit hit;
    for (int i = 0; i < maxSteps; i++) {
        float3 p = ro + rd * t;
        hit = eh_map(p, r, u, reliefTex);
        if (hit.d < minD) { minD = hit.d; tMin = t; }
        if (hit.d < eps) { hitSurface = true; break; }
        t += hit.d * 0.85;
        if (t > 2.80) break;
    }

    float alpha;
    float3 p;
    if (hitSurface) {
        alpha = 1.0;
        p = ro + rd * t;
    } else if (minD < aa) {
        alpha = 1.0 - minD / aa;
        p = ro + rd * tMin;
        hit = eh_map(p, r, u, reliefTex);
    } else {
        return float4(0.0);
    }

    float3 col = eh_shade(p, rd, hit, r, u, albedoTex, reliefTex);
    col = 1.0 - exp(-col * 1.15);               // filmic shoulder
    col = pow(max(col, 0.0), float3(1.0 / 2.2));
    alpha *= smoothstep(-1.95, -1.35, p.y);     // neck fades out toward the bottom of the quad
    alpha *= u.params.x;
    return float4(col * alpha, alpha);
}
