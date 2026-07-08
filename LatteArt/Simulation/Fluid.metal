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

fragment float4 f_latte(VOut in [[stage_in]],
                        texture2d<float> dye [[texture(0)]],
                        constant OcclusionUniform &occl [[buffer(0)]])
{
    float2 c = in.uv - 0.5;
    float r = length(c);
    float d = clamp(dye.sample(linSmp, in.uv).x, 0.0, 1.0);
    float3 crema = float3(0.32, 0.19, 0.10);
    float3 milk  = float3(0.97, 0.96, 0.93);
    float3 latte = mix(crema, milk, d);
    // Paintable coffee disc now fills to the CupSpace rim (r = 0.5 in UV);
    // ~0.008-wide smoothstep at the edge for AA, no wall ring.
    float inside = smoothstep(0.5, 0.492, r);

    // Cut a soft hole at each depth-verified-closer pitcher tag position, so
    // the real pitcher (genuinely nearer the camera than the cup surface
    // there) visually wins over the disc instead of the disc always drawing
    // on top of it.
    float occlusion = 1.0;
    if (occl.active0 > 0.5) {
        float dist0 = length(in.uv - occl.uv0);
        occlusion = min(occlusion, smoothstep(occl.radius0 * 0.7, occl.radius0, dist0));
    }
    if (occl.active1 > 0.5) {
        float dist1 = length(in.uv - occl.uv1);
        occlusion = min(occlusion, smoothstep(occl.radius1 * 0.7, occl.radius1, dist1));
    }

    // Alpha carries coverage so the blitter (sourceAlpha/oneMinusSourceAlpha)
    // composites the disc over anything and leaves the outside (and now the
    // pitcher's hole) untouched — fully transparent there.
    return float4(latte, inside * occlusion);
}
