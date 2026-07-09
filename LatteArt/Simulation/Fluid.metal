#include <metal_stdlib>
using namespace metal;

// 2D Stam "Stable Fluids" (GDC'03) after GPU Gems ch.38, on ping-pong textures.
// Velocity is stored in grid cells/second. All kernels bounds-check gid so we
// can dispatch ceil-divided threadgroups without non-uniform support.

constexpr sampler linSmp(coord::normalized, address::clamp_to_edge, filter::linear);

static inline uint2 clampCoord(int2 c, uint w, uint h) {
    return uint2(clamp(c, int2(0), int2(int(w) - 1, int(h) - 1)));
}

kernel void k_clear(texture2d<float, access::write> tex [[texture(0)]],
                    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= tex.get_width() || gid.y >= tex.get_height()) return;
    tex.write(float4(0), gid);
}

// Semi-Lagrangian advection — unconditionally stable, the reason this solver
// survives demo-day frame hiccups.
kernel void k_advect(texture2d<float, access::sample> src [[texture(0)]],
                     texture2d<float, access::sample> vel [[texture(1)]],
                     texture2d<float, access::write>  dst [[texture(2)]],
                     constant float &dt          [[buffer(0)]],
                     constant float &dissipation [[buffer(1)]],
                     uint2 gid [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 size = float2(w, h);
    float2 uv = (float2(gid) + 0.5) / size;
    float2 v = vel.sample(linSmp, uv).xy;         // cells/sec
    float2 prev = uv - dt * v / size;
    dst.write(src.sample(linSmp, prev) * dissipation, gid);
}

// Gaussian splat: the inject(position, radius, dye|momentum) primitive.
kernel void k_splat(texture2d<float, access::read>  src [[texture(0)]],
                    texture2d<float, access::write> dst [[texture(1)]],
                    constant float2 &pt     [[buffer(0)]],   // uv
                    constant float  &radius [[buffer(1)]],   // uv units
                    constant float4 &value  [[buffer(2)]],
                    uint2 gid [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 uv = (float2(gid) + 0.5) / float2(w, h);
    float2 d = uv - pt;
    float g = exp(-dot(d, d) / (radius * radius));
    dst.write(src.read(gid) + value * g, gid);
}

kernel void k_divergence(texture2d<float, access::read>  vel [[texture(0)]],
                         texture2d<float, access::write> div [[texture(1)]],
                         uint2 gid [[thread_position_in_grid]])
{
    uint w = div.get_width(), h = div.get_height();
    if (gid.x >= w || gid.y >= h) return;
    int2 g = int2(gid);
    float L = vel.read(clampCoord(g + int2(-1, 0), w, h)).x;
    float R = vel.read(clampCoord(g + int2( 1, 0), w, h)).x;
    float B = vel.read(clampCoord(g + int2(0, -1), w, h)).y;
    float T = vel.read(clampCoord(g + int2(0,  1), w, h)).y;
    div.write(float4(0.5 * ((R - L) + (T - B)), 0, 0, 0), gid);
}

// Volume source: new foam occupies area, so the surface must move aside.
// Injecting outward velocity directly would be erased by the projection
// (it removes divergence); instead we bias the divergence INPUT — the
// solver then leaves real +S divergence in the field, a self-consistent
// outward source whose flow shape the pressure solve derives itself.
kernel void k_divergenceSource(texture2d<float, access::read>  div [[texture(0)]],
                               texture2d<float, access::write> out [[texture(1)]],
                               constant float2 &pt     [[buffer(0)]],
                               constant float  &radius [[buffer(1)]],
                               constant float  &amount [[buffer(2)]],
                               uint2 gid [[thread_position_in_grid]])
{
    uint w = out.get_width(), h = out.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 uv = (float2(gid) + 0.5) / float2(w, h);
    float2 d = uv - pt;
    float g = exp(-dot(d, d) / (radius * radius));
    out.write(div.read(gid) - float4(amount * g, 0, 0, 0), gid);
}

kernel void k_jacobi(texture2d<float, access::read>  p    [[texture(0)]],
                     texture2d<float, access::read>  div  [[texture(1)]],
                     texture2d<float, access::write> pOut [[texture(2)]],
                     uint2 gid [[thread_position_in_grid]])
{
    uint w = pOut.get_width(), h = pOut.get_height();
    if (gid.x >= w || gid.y >= h) return;
    int2 g = int2(gid);
    float L = p.read(clampCoord(g + int2(-1, 0), w, h)).x;
    float R = p.read(clampCoord(g + int2( 1, 0), w, h)).x;
    float B = p.read(clampCoord(g + int2(0, -1), w, h)).x;
    float T = p.read(clampCoord(g + int2(0,  1), w, h)).x;
    float d = div.read(gid).x;
    pOut.write(float4((L + R + B + T - d) * 0.25, 0, 0, 0), gid);
}

kernel void k_subtractGradient(texture2d<float, access::read>  p      [[texture(0)]],
                               texture2d<float, access::read>  vel    [[texture(1)]],
                               texture2d<float, access::write> velOut [[texture(2)]],
                               uint2 gid [[thread_position_in_grid]])
{
    uint w = velOut.get_width(), h = velOut.get_height();
    if (gid.x >= w || gid.y >= h) return;
    int2 g = int2(gid);
    float L = p.read(clampCoord(g + int2(-1, 0), w, h)).x;
    float R = p.read(clampCoord(g + int2( 1, 0), w, h)).x;
    float B = p.read(clampCoord(g + int2(0, -1), w, h)).x;
    float T = p.read(clampCoord(g + int2(0,  1), w, h)).x;
    float2 v = vel.read(gid).xy - 0.5 * float2(R - L, T - B);
    velOut.write(float4(v, 0, 0), gid);
}

// Rayleigh friction + wall no-slip. A latte surface is a THIN layer of
// near-paste microfoam: bottom drag and foam viscosity kill momentum within
// ~a second, and the cup wall pins velocity to zero. Without this the solver
// behaves like open water — one nudge sloshes wall to wall.
kernel void k_dampVelocity(texture2d<float, access::read>  vel [[texture(0)]],
                           texture2d<float, access::write> out [[texture(1)]],
                           constant float &damping [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]])
{
    uint w = out.get_width(), h = out.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 uv = (float2(gid) + 0.5) / float2(w, h);
    float r = length(uv - 0.5);
    float wall = smoothstep(0.50, 0.47, r);   // 1 inside the cup, 0 at/outside the rim
    out.write(vel.read(gid) * damping * wall, gid);
}

// ---- procedural surface detail (crema mottle, foam grain) ----
//
// Cheap hash-based value noise, evaluated in cup UV so the detail is pinned
// to the cup, not the screen. The dye field advects OVER this static detail;
// visually that reads fine (crema mottling is quasi-static during a pour)
// and costs no extra textures or assets.

static inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 345.45));
    p += dot(p, p + 34.345);
    return fract(p.x * p.y);
}

static inline float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1, 0));
    float c = hash21(i + float2(0, 1));
    float d = hash21(i + float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// 3 octaves is enough for crema marbling; more is invisible at cup size.
static inline float fbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 3; i++) {
        v += a * vnoise(p);
        p = p * 2.03 + 17.7;
        a *= 0.5;
    }
    return v;
}

// ---- display: dye texture -> latte surface (brown canvas, white milk) ----
//
// The quad is placed by CupPose (via CupVertex, computed in FluidBlitter) so
// it maps 1:1 onto the on-screen cup ellipse; the compositor / blitter
// alpha-blends the result over whatever is behind it (dark grey in the debug
// harness, the camera later).

// Placement math (recovering isotropic pixels, scaling, rotating, and only
// THEN converting to anisotropic clip space) happens in Swift — see
// FluidBlitter.cupQuadVertices. Rotating a quad that's already been scaled
// into clip space is only correct when the viewport is square; a full-screen
// portrait view isn't, so that math has to happen in real pixels first. The
// shader just places the 4 corners it's given.
struct CupVertex {
    float2 posNDC;
    float2 uv;
};

struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut v_cupQuad(uint vid [[vertex_id]],
                      constant CupVertex *verts [[buffer(0)]])
{
    VOut o;
    o.pos = float4(verts[vid].posNDC, 0, 1);
    o.uv = verts[vid].uv;
    return o;
}

// `in.uv` is already in CupSpace UV terms (center 0.5,0.5, rim at 0.5) — the
// quad is placed to map its [0,1] square 1:1 onto the cup, same convention
// the dye texture sample above already relies on.
//
// Both slots are REAL depth-tested on the Swift side before being marked
// active (CameraPourCoordinator: ray-cast from the camera through the tag to
// the cup's actual tracked plane, compare that intersection's distance from
// the camera against the tag's own known distance) — a slot is only active
// when the pitcher tag is genuinely closer to the camera than the cup
// surface is at that screen location, not just "whenever a tag is visible".
// Radius is the tag's real physical size (AprilTagRoles.pitcherTagSizeMeters)
// projected into cup-UV units, not a guessed constant.
struct OcclusionUniform {
    float2 uv0;   float radius0;   float active0;
    float2 uv1;   float radius1;   float active1;
};

// Per-pixel scene-depth occlusion (LiDAR devices) — the CLEAN path. ARKit's
// sceneDepth gives the real measured depth of the scene at every pixel; the
// fragment shader compares it against the cup plane's own depth at that same
// pixel and hides the surface exactly where the real world (pitcher, hand) is
// measurably in front of the plane. That yields the pitcher's true silhouette
// rather than a circle around a tag. Field order/size must match the Swift
// mirror in FluidBlitter.swift.
struct DepthOcclusionUniform {
    float4x4 inverseViewProjection;  // clip -> world, for unprojecting pixels to rays
    float3 cameraPos;                // world
    float3 cameraForward;            // world, unit; ARKit depth = meters along this axis
    float3 planePoint;               // tracked cup plane (rim circle center)
    float3 planeNormal;              // unit
    float4 viewToImage;              // CGAffineTransform a,b,c,d: view UV -> depth-map UV
    float2 viewToImageT;             // tx, ty
    float2 drawableSize;             // render-target pixels, normalizes in.pos
    float enabled;                   // 0 = use the tag-circle fallback below
    float margin;                    // meters the scene must be nearer than the plane to occlude
    float2 pad;
};

// Depth is r32Float — not linearly filterable on all GPUs, and blending
// depths across an object edge invents depths that exist nowhere; nearest is
// both safe and correct here.
constexpr sampler depthSmp(coord::normalized, address::clamp_to_edge, filter::nearest);

fragment float4 f_latte(VOut in [[stage_in]],
                        texture2d<float> dye [[texture(0)]],
                        texture2d<float> sceneDepth [[texture(1)]],
                        constant OcclusionUniform &occl [[buffer(0)]],
                        constant DepthOcclusionUniform &depthU [[buffer(1)]])
{
    float2 c = in.uv - 0.5;
    float r = length(c);
    float d = clamp(dye.sample(linSmp, in.uv).x, 0.0, 1.0);

    // Crema: not one flat brown — broad fbm marbling between a dark and a
    // lighter reddish tone plus a fine speckle, darkening toward the wall
    // (real crema collects a darker ring at the cup edge).
    float marble = fbm(in.uv * 22.0);
    float speck  = vnoise(in.uv * 160.0);
    float3 crema = mix(float3(0.26, 0.155, 0.085), float3(0.45, 0.28, 0.15),
                       clamp(0.2 + 0.8 * marble + 0.18 * (speck - 0.5), 0.0, 1.0));
    crema *= 1.0 - 0.22 * smoothstep(0.36, 0.5, r);

    // Milk: microfoam, not paint — a near-white base dimmed by two scales of
    // bubble grain so it reads matte and slightly porous.
    float grain = 0.5 * vnoise(in.uv * 300.0) + 0.5 * vnoise(in.uv * 120.0);
    float3 foam = float3(0.985, 0.965, 0.93) - float3(0.10, 0.09, 0.07) * grain;

    // Thin milk over crema is warm tan (milk mixing INTO the crema), never
    // gray — a two-stop ramp instead of one straight crema→white mix.
    float3 cream = float3(0.78, 0.62, 0.45);
    float foamMask = smoothstep(0.30, 0.85, d);
    float3 latte = mix(crema, cream, smoothstep(0.04, 0.35, d));
    latte = mix(latte, foam, foamMask);

    // Relief: treat the dye field as a height map (foam sits proud of the
    // liquid). A fixed key light from the screen's upper-left shades the
    // pattern's edges so the white reads as a raised layer, plus a wet
    // specular sheen that's strong on the glossy liquid crema and nearly
    // gone on settled matte foam. Purely cosmetic — no physics reads this.
    float2 texel = float2(1.0) / float2(dye.get_width(), dye.get_height());
    float dR = dye.sample(linSmp, in.uv + float2(texel.x, 0)).x;
    float dL = dye.sample(linSmp, in.uv - float2(texel.x, 0)).x;
    float dT = dye.sample(linSmp, in.uv + float2(0, texel.y)).x;
    float dB = dye.sample(linSmp, in.uv - float2(0, texel.y)).x;
    float3 nrm = normalize(float3(dL - dR, dB - dT, 0.55));
    float3 lightDir = normalize(float3(-0.4, -0.55, 0.73));
    latte *= 0.88 + 0.24 * max(dot(nrm, lightDir), 0.0);
    float spec = pow(max(dot(normalize(lightDir + float3(0, 0, 1)), nrm), 0.0), 24.0);
    latte += spec * mix(0.09, 0.02, foamMask);

    // Paintable coffee disc now fills to the CupSpace rim (r = 0.5 in UV);
    // ~0.008-wide smoothstep at the edge for AA, no wall ring.
    float inside = smoothstep(0.5, 0.492, r);

    float occlusion = 1.0;
    if (depthU.enabled > 0.5) {
        // Per-pixel occlusion from the real depth map: the true silhouette
        // of whatever is actually in front of the cup plane at this pixel.
        float2 viewUV = in.pos.xy / depthU.drawableSize;
        float2 imgUV = float2(
            depthU.viewToImage.x * viewUV.x + depthU.viewToImage.z * viewUV.y + depthU.viewToImageT.x,
            depthU.viewToImage.y * viewUV.x + depthU.viewToImage.w * viewUV.y + depthU.viewToImageT.y);
        if (all(imgUV >= 0.0) && all(imgUV <= 1.0)) {
            float sceneZ = sceneDepth.sample(depthSmp, imgUV).x;   // meters; <=0 means no data
            if (sceneZ > 0.0) {
                // The cup plane's depth at THIS pixel: unproject the pixel to
                // a world ray, intersect with the tracked plane, measure the
                // hit along the camera-forward axis — the same z-depth metric
                // ARKit's depth map reports.
                float2 ndc = float2(2.0 * viewUV.x - 1.0, 1.0 - 2.0 * viewUV.y);
                float4 wp = depthU.inverseViewProjection * float4(ndc, 0.5, 1.0);
                float3 rayDir = normalize(wp.xyz / wp.w - depthU.cameraPos);
                float denom = dot(rayDir, depthU.planeNormal);
                if (abs(denom) > 1e-5) {
                    float t = dot(depthU.planePoint - depthU.cameraPos, depthU.planeNormal) / denom;
                    if (t > 0.0) {
                        float3 hit = depthU.cameraPos + t * rayDir;
                        float surfaceZ = dot(hit - depthU.cameraPos, depthU.cameraForward);
                        // Fully opaque while the scene sits at/behind the
                        // plane (the liquid, the rim), fully hidden once it's
                        // clearly in front (the pitcher) — only a 1 cm soft
                        // band between, so the cut is a hard silhouette, not
                        // a translucent fade. `margin` absorbs plane-tracking
                        // noise so the rim itself never flickers.
                        occlusion = smoothstep(surfaceZ - depthU.margin - 0.01,
                                               surfaceZ - depthU.margin, sceneZ);
                    }
                }
            }
        }
    } else {
        // Fallback (no LiDAR): hard-edged holes at each depth-verified-closer
        // pitcher tag, depth-tested on the Swift side (CameraPourCoordinator).
        // Thin ~3% AA band only — a wider fade reads as the surface turning
        // TRANSPARENT around the pitcher rather than the pitcher sitting on
        // top of an opaque surface.
        if (occl.active0 > 0.5) {
            float dist0 = length(in.uv - occl.uv0);
            occlusion = min(occlusion, smoothstep(occl.radius0 * 0.97, occl.radius0, dist0));
        }
        if (occl.active1 > 0.5) {
            float dist1 = length(in.uv - occl.uv1);
            occlusion = min(occlusion, smoothstep(occl.radius1 * 0.97, occl.radius1, dist1));
        }
    }

    // Alpha carries coverage so the blitter (sourceAlpha/oneMinusSourceAlpha)
    // composites the disc over anything and leaves the outside (and now the
    // pitcher's hole) untouched — fully transparent there.
    return float4(latte, inside * occlusion);
}
