#include <metal_stdlib>
using namespace metal;

// ============================================================================
//  Contained Stable-Fluids solver (Jos Stam) with a CUP SOLID BOUNDARY.
//  ---------------------------------------------------------------------------
//  Unlike a mask-at-render approach, the cup wall is a real boundary the solver
//  respects on every pass, so fluid STAYS IN THE CUP, glides along the rim
//  (free-slip), and folds back inward — the motion latte art actually needs.
//
//  Channels:
//    velocity : RG float  (vx, vy)          — real fluid mechanics
//    dye      : R  float   (milk concentration, painted) — advected passively
//    height   : R  float   (light surface displacement)  — advected + relaxed,
//                                                          used only for shading
//
//  HONESTY NOTE: the real liquid is plain WATER. There is no water-vs-milk
//  density physics. Advection + incompressible projection are real and act on
//  the velocity field. "Milk" and "crema" are invented at render time. This is
//  the deliberate fiction: real motion, painted coffee.
// ============================================================================

constant float GRID = 256.0;
constant float RDX  = 1.0 / 256.0;   // grid cell size in UV

// Shared parameter block. MUST match `FluidParams` in FluidSimulation.swift
// (same field order, same sizes, float2 is 8-byte aligned -> total 32 bytes).
struct FluidParams {
    float2 cupCenter;         // cup center in UV
    float  cupRadius;         // cup radius in UV
    float  dt;                // timestep
    float  velDissipation;    // velocity decay per step
    float  dyeDissipation;    // milk decay per step
    float  heightDissipation; // surface relaxation toward flat
    float  wallDrag;          // 0 = free-slip, 1 = no-slip near the rim
};

// ---- boundary helpers ------------------------------------------------------

inline float2 cellUV(uint2 g)                 { return (float2(g) + 0.5) * RDX; }
inline bool    inCup(float2 uv, constant FluidParams& P) {
    return distance(uv, P.cupCenter) <= P.cupRadius;
}
inline bool    cellInCup(uint2 g, constant FluidParams& P) {
    return inCup(cellUV(g), P);
}
// Pull a UV point back onto the cup if it strayed outside.
inline float2  clampToCupUV(float2 uv, constant FluidParams& P) {
    float2 d = uv - P.cupCenter;
    float  len = length(d);
    if (len <= P.cupRadius) return uv;
    return P.cupCenter + d / max(len, 1e-6) * P.cupRadius;
}
inline uint2   clampGrid(int2 g) {
    int N = int(GRID) - 1;
    return uint2(clamp(g.x, 0, N), clamp(g.y, 0, N));
}

static float2 sampleVel(texture2d<float, access::sample> tex, sampler s, float2 uv) {
    return tex.sample(s, uv).rg;
}

// ----------------------------------------------------------------------------
//  ADVECT: q_new(x) = q_old(x - v*dt), with the backtrace clamped into the cup
//  so nothing is pulled in from outside the wall. Generic over vel/dye/height.
// ----------------------------------------------------------------------------
kernel void advect(texture2d<float, access::sample> velIn   [[texture(0)]],
                   texture2d<float, access::sample> srcIn   [[texture(1)]],
                   texture2d<float, access::write>  dstOut  [[texture(2)]],
                   constant FluidParams& P                  [[buffer(0)]],
                   constant float& dissipation              [[buffer(1)]],
                   uint2 gid                                [[thread_position_in_grid]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);

    float2 uv = cellUV(gid);
    if (!inCup(uv, P)) { dstOut.write(float4(0), gid); return; }   // solid cell

    float2 v   = sampleVel(velIn, s, uv);
    float2 pos = clampToCupUV(uv - P.dt * v * RDX, P);             // stay in cup
    float4 q   = srcIn.sample(s, pos);

    dstOut.write(q * dissipation, gid);
}

// ----------------------------------------------------------------------------
//  DIVERGENCE with free-slip walls: a solid neighbor contributes a GHOST
//  velocity that mirrors the tangential component and cancels the normal one,
//  so there is no flux through the rim.
// ----------------------------------------------------------------------------
kernel void divergence(texture2d<float, access::read>  vel   [[texture(0)]],
                       texture2d<float, access::write> div   [[texture(1)]],
                       constant FluidParams& P               [[buffer(0)]],
                       uint2 gid                             [[thread_position_in_grid]]) {
    if (!cellInCup(gid, P)) { div.write(float4(0), gid); return; }

    int2 g = int2(gid);
    float2 vC = vel.read(gid).rg;

    uint2 lC = clampGrid(g + int2(-1, 0));
    uint2 rC = clampGrid(g + int2( 1, 0));
    uint2 bC = clampGrid(g + int2( 0,-1));
    uint2 tC = clampGrid(g + int2( 0, 1));

    float2 vL = cellInCup(lC, P) ? vel.read(lC).rg : float2(-vC.x,  vC.y);
    float2 vR = cellInCup(rC, P) ? vel.read(rC).rg : float2(-vC.x,  vC.y);
    float2 vB = cellInCup(bC, P) ? vel.read(bC).rg : float2( vC.x, -vC.y);
    float2 vT = cellInCup(tC, P) ? vel.read(tC).rg : float2( vC.x, -vC.y);

    float d = 0.5 * ((vR.x - vL.x) + (vT.y - vB.y));
    div.write(float4(d, 0, 0, 0), gid);
}

// ----------------------------------------------------------------------------
//  JACOBI pressure iteration. Solid neighbor -> Neumann (dp/dn = 0): substitute
//  the center pressure. Run ~20-40x.
// ----------------------------------------------------------------------------
kernel void jacobi(texture2d<float, access::read>  pIn   [[texture(0)]],
                   texture2d<float, access::read>  div   [[texture(1)]],
                   texture2d<float, access::write> pOut  [[texture(2)]],
                   constant FluidParams& P               [[buffer(0)]],
                   uint2 gid                             [[thread_position_in_grid]]) {
    if (!cellInCup(gid, P)) { pOut.write(float4(0), gid); return; }

    int2 g = int2(gid);
    float pC = pIn.read(gid).r;

    uint2 lC = clampGrid(g + int2(-1, 0));
    uint2 rC = clampGrid(g + int2( 1, 0));
    uint2 bC = clampGrid(g + int2( 0,-1));
    uint2 tC = clampGrid(g + int2( 0, 1));

    float pL = cellInCup(lC, P) ? pIn.read(lC).r : pC;
    float pR = cellInCup(rC, P) ? pIn.read(rC).r : pC;
    float pB = cellInCup(bC, P) ? pIn.read(bC).r : pC;
    float pT = cellInCup(tC, P) ? pIn.read(tC).r : pC;
    float b  = div.read(gid).r;

    float p = (pL + pR + pB + pT - b) * 0.25;
    pOut.write(float4(p, 0, 0, 0), gid);
}

// ----------------------------------------------------------------------------
//  SUBTRACT pressure gradient -> divergence-free velocity. Solid neighbor uses
//  center pressure (no gradient through the wall). Velocity is zeroed in solid
//  cells and lightly dragged near the rim by wallDrag.
// ----------------------------------------------------------------------------
kernel void subtractGradient(texture2d<float, access::read>  p      [[texture(0)]],
                             texture2d<float, access::read>  velIn  [[texture(1)]],
                             texture2d<float, access::write> velOut [[texture(2)]],
                             constant FluidParams& P                [[buffer(0)]],
                             uint2 gid                              [[thread_position_in_grid]]) {
    if (!cellInCup(gid, P)) { velOut.write(float4(0), gid); return; }

    int2 g = int2(gid);
    float pC = p.read(gid).r;

    uint2 lC = clampGrid(g + int2(-1, 0));
    uint2 rC = clampGrid(g + int2( 1, 0));
    uint2 bC = clampGrid(g + int2( 0,-1));
    uint2 tC = clampGrid(g + int2( 0, 1));

    float pL = cellInCup(lC, P) ? p.read(lC).r : pC;
    float pR = cellInCup(rC, P) ? p.read(rC).r : pC;
    float pB = cellInCup(bC, P) ? p.read(bC).r : pC;
    float pT = cellInCup(tC, P) ? p.read(tC).r : pC;

    float2 v = velIn.read(gid).rg;
    v -= 0.5 * float2(pR - pL, pT - pB);

    // A touch of drag in the boundary band reads as realistic wall friction.
    float2 uv = cellUV(gid);
    float  edge = smoothstep(P.cupRadius, P.cupRadius - 0.06, distance(uv, P.cupCenter));
    v *= mix(1.0, 1.0 - 0.5 * P.wallDrag, 1.0 - edge);

    velOut.write(float4(v, 0, 0), gid);
}

// ----------------------------------------------------------------------------
//  RELAX HEIGHT: gentle diffusion + decay so the pour dimple spreads and the
//  surface settles back to flat. Cheap; drives shading only.
// ----------------------------------------------------------------------------
kernel void relaxHeight(texture2d<float, access::read>  hIn  [[texture(0)]],
                        texture2d<float, access::write> hOut [[texture(1)]],
                        constant FluidParams& P              [[buffer(0)]],
                        uint2 gid                            [[thread_position_in_grid]]) {
    if (!cellInCup(gid, P)) { hOut.write(float4(0), gid); return; }

    int2 g = int2(gid);
    float hC = hIn.read(gid).r;
    float hL = hIn.read(clampGrid(g + int2(-1, 0))).r;
    float hR = hIn.read(clampGrid(g + int2( 1, 0))).r;
    float hB = hIn.read(clampGrid(g + int2( 0,-1))).r;
    float hT = hIn.read(clampGrid(g + int2( 0, 1))).r;

    float blurred = mix(hC, 0.25 * (hL + hR + hB + hT), 0.35);
    hOut.write(float4(blurred * P.heightDissipation, 0, 0, 0), gid);
}

// ----------------------------------------------------------------------------
//  SPLAT: inject a Gaussian of `value` into the source field at `center` (UV).
//  Used for velocity (force.xy), milk dye (x), and height dimple (x). Only
//  affects cells inside the cup. This is the ONLY place pour input enters.
// ----------------------------------------------------------------------------
kernel void splat(texture2d<float, access::read>  srcIn   [[texture(0)]],
                  texture2d<float, access::write> dstOut  [[texture(1)]],
                  constant FluidParams& P                 [[buffer(0)]],
                  constant float2& center                 [[buffer(1)]],  // UV
                  constant float3& value                  [[buffer(2)]],
                  constant float&  radius                 [[buffer(3)]],  // UV
                  uint2 gid                               [[thread_position_in_grid]]) {
    float2 uv = cellUV(gid);
    float4 base = srcIn.read(gid);
    if (!inCup(uv, P)) { dstOut.write(base, gid); return; }

    float2 d = uv - center;
    float  g = exp(-dot(d, d) / max(radius * radius, 1e-6));
    base.rgb += value * g;
    dstOut.write(base, gid);
}

// ----------------------------------------------------------------------------
//  RENDER: dye -> crema/milk, with fill-level fade-in and height-based shading.
//  Transparent (alpha 0) outside the cup so the camera feed shows through.
// ----------------------------------------------------------------------------
kernel void renderCrema(texture2d<float, access::read>  dye    [[texture(0)]],
                        texture2d<float, access::read>  height [[texture(1)]],
                        texture2d<float, access::write> out    [[texture(2)]],
                        constant FluidParams& P                [[buffer(0)]],
                        constant float& fillLevel              [[buffer(1)]],
                        uint2 gid                              [[thread_position_in_grid]]) {
    float2 uv = cellUV(gid);
    float  r  = distance(uv, P.cupCenter);

    if (r > P.cupRadius) { out.write(float4(0), gid); return; }   // outside cup

    float c = clamp(dye.read(gid).r, 0.0, 1.0);

    float3 crema = float3(0.42, 0.24, 0.11);   // espresso crema
    float3 milk  = float3(0.96, 0.93, 0.88);   // microfoam white
    float  t     = smoothstep(0.12, 0.80, c);
    float3 col   = mix(crema, milk, t);

    // Fill level fades the crema in from a near-empty dark cup (Focus B).
    float3 empty = float3(0.05, 0.035, 0.025);
    col = mix(empty, col, smoothstep(0.0, 0.30, fillLevel));

    // Surface shading from the height field: normal -> soft diffuse + specular.
    int2 g = int2(gid);
    float hL = height.read(clampGrid(g + int2(-1, 0))).r;
    float hR = height.read(clampGrid(g + int2( 1, 0))).r;
    float hB = height.read(clampGrid(g + int2( 0,-1))).r;
    float hT = height.read(clampGrid(g + int2( 0, 1))).r;
    float3 n = normalize(float3(-(hR - hL) * 6.0, -(hT - hB) * 6.0, 1.0));
    float3 L = normalize(float3(0.35, 0.35, 1.0));
    float  diff = saturate(dot(n, L));
    float  spec = pow(saturate(dot(n, normalize(L + float3(0, 0, 1.0)))), 24.0);
    col = col * (0.88 + 0.12 * diff) + spec * 0.20;

    // Soft feathered rim so it sits in the cup naturally.
    float edge = smoothstep(P.cupRadius, P.cupRadius - 0.02, r);
    out.write(float4(col, edge), gid);
}

// ----------------------------------------------------------------------------
//  Fullscreen-quad blit: draw a sim texture to the screen.
// ----------------------------------------------------------------------------
struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut fsQuadVertex(uint vid [[vertex_id]]) {
    float2 p[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };
    VOut o;
    o.pos = float4(p[vid], 0, 1);
    o.uv = float2((p[vid].x + 1) * 0.5, 1.0 - (p[vid].y + 1) * 0.5);
    return o;
}

// Draws the sim texture into a positioned quad (the cup's bounding box in NDC),
// so the sim's inscribed cup-circle lands exactly on the cup ellipse on screen.
struct QuadRect { float2 centerNDC; float2 halfSizeNDC; };

vertex VOut texturedQuadVertex(uint vid [[vertex_id]],
                               constant QuadRect& rect [[buffer(0)]]) {
    float2 corner[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
    float2 c = corner[vid];
    VOut o;
    o.pos = float4(rect.centerNDC + c * rect.halfSizeNDC, 0, 1);
    o.uv  = float2((c.x + 1) * 0.5, 1.0 - (c.y + 1) * 0.5);
    return o;
}

fragment float4 fsQuadFragment(VOut in [[stage_in]],
                               texture2d<float, access::sample> tex [[texture(0)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    return tex.sample(s, in.uv);
}

// ----------------------------------------------------------------------------
//  CLEAR kernels — zero a texture (format-agnostic).
// ----------------------------------------------------------------------------
kernel void clearTex(texture2d<float, access::write> t [[texture(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
    t.write(float4(0), gid);
}
