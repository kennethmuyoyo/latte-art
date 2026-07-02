# Latte Art Trainer — Technical Spec

> A tripod-mounted iPhone watches a real cup from above. The user pours **water**
> (not milk, not coffee — plain water in both jug and cup); the app tracks where
> the pour lands and **simulates** the fluid to *look* like espresso crema and
> milk. It keeps the simulated fluid **inside the cup**, tracks how full the cup
> is, and coaches the user through forming a chosen pattern (tulip / heart /
> rosetta).

This spec plans the whole app but goes deep on the two hard, currently-missing
pieces called out first: **containing the fluid inside the cup** and **tracking
the liquid level**. Everything else is scoped enough to build against.

---

## 1. Decisions locked

| Question | Decision |
|---|---|
| Pour input | **Vision tracks the real pour** — ARKit + Vision detect the milk stream / jug tip and where it meets the cup surface. |
| Render surface | **AR overlay on the live cup** — camera feed with the Metal fluid composited inside the detected cup circle. |
| Liquid level | **Both** — a fullness scalar (0→1) that drives app logic, plus a light 2D height field for surface shading. |

Deferred but designed-for: everything sits behind a `PourSource` interface so a
touch/drag driver can stand in for Vision while the physics is tuned.

### 1.1 Physical material: water, not milk (key constraint)
The real liquid is **plain water** in both jug and cup. There is no real coffee,
crema, or milk anywhere in the scene — **all of it is simulated and painted by the
app**. The camera's only job is to tell the sim *where and how* the user is
pouring; the sim invents the entire coffee/milk look on top.

Consequences that ripple through the design:
- **Pour tracking cannot rely on a visible milk stream.** Clear water is nearly
  invisible on camera (no color/brightness contrast). Vision must instead track
  the **jug/spout** and the **surface disturbance** the pour makes (see §6).
- **The base and foam are both fictional.** During FillCup the app renders rising
  crema even though the cup is filling with clear water; during FormArt it injects
  simulated *milk* dye at the tracked pour point.
- **Cup detection is easier, pour detection is harder.** A clean cup rim is a
  strong visual target; a clear-water stream is a weak one. Budget CV effort
  accordingly, and lean on the jug + ripple cues plus smoothing.

---

## 2. App flow (state machine)

```
Setup ─▶ PatternSelect ─▶ FillCup ─▶ ReadyForFoam ─▶ FormArt ─▶ Result
```

1. **Setup** — instructions: mount tripod, place cup, fill jug. Confirm cup is
   detected (ARKit finds the cup rim → gives us `center`, `radius` in view space).
2. **PatternSelect** — user picks tulip / heart / rosetta.
3. **FillCup** — user pours espresso/water base. Sim runs *inside the cup*; we
   track pour landing position and rising **fill level**. A target pour path is
   shown (the "DO THIS" swirl-in-center from the reference clips). Live feedback:
   on-path vs off-path.
4. **ReadyForFoam** — triggered when fill level ≥ threshold. Sim shows a settled
   crema surface. Prompt: "Base ready — start the foam pour."
5. **FormArt** — the pattern-forming phase. Guidance arrows show pour points and
   directions (per reference images). Milk dye is injected at the tracked pour
   point; the fluid solver drags it into the pattern. Real-time on-track / missed
   feedback (✅ / ❌ overlay).
6. **Result** — final rendered pattern + a score vs the ideal template.

---

## 3. Module architecture

```
┌───────────────────────────────────────────────────────────────┐
│ App (SwiftUI)                                                   │
│  AppFlowModel  ── owns phase state machine, pattern choice      │
└───────────────┬───────────────────────────────────┬───────────┘
                │                                     │
     ┌──────────▼──────────┐              ┌───────────▼───────────┐
     │ Perception          │              │ Simulation            │
     │  ARSessionManager   │  PourSample  │  FluidSimulation      │
     │  CupDetector (Vision│ ───────────▶ │   (Metal compute)     │
     │  + ARKit)           │              │  LevelModel           │
     │  PourTracker (Vision│              │   (fullness+height)   │
     └──────────┬──────────┘              └───────────┬───────────┘
                │ camera texture + cup transform      │ fluid texture (RGBA, α-masked)
                └───────────────┬─────────────────────┘
                                ▼
                       ┌─────────────────┐
                       │ AR Compositor   │  camera feed + fluid overlay
                       │  (MetalKit)     │  + guidance layer (CoreGraphics)
                       └─────────────────┘
```

- **Perception** — camera, cup detection, pour tracking. Output is a stream of
  `PourSample { uvPosition, velocity, flowRate, timestamp }` in cup-normalized
  coordinates, plus the current cup transform.
- **Simulation** — the fluid solver + level model. Consumes `PourSample`s,
  produces a fluid texture and a `fillLevel`.
- **AR Compositor** — draws camera feed, then the α-masked fluid inside the cup,
  then the CoreGraphics guidance layer (arrows, path, ✅/❌).
- **App** — orchestrates phases and pattern selection.

---

## 4. FOCUS A — Fluid contained inside the cup

### 4.1 Problem with the current shader
`Fluid.metal` runs the Stable-Fluids solve on the full 256² grid and only masks
to a circle in `renderCremaMasked`. So velocity advects and projects across the
whole square: fluid leaks past the rim, swirl energy drains into the corners, and
the wall exerts no push-back. It *looks* clipped but isn't *contained*.

### 4.2 Approach: solid-boundary Stable-Fluids
Introduce the cup as a **solid boundary** the solver respects on every pass.

- **Cup definition.** Cup interior = `distance(uv, center) ≤ radius`. Passed to
  kernels as `float2 center, float radius` (UV space), sourced live from the cup
  detector. A helper `bool inCup(uv)` gates every kernel. (Optionally precompute a
  mask/SDF texture once per detection update for speed and softer walls.)

- **Boundary conditions (free-slip walls — keeps swirl alive):**
  - *Advection*: if the backtrace lands outside the cup, don't pull from outside —
    clamp the sample point back onto the boundary (or fall back to the cell's own
    value). Zero the result in solid cells.
  - *Divergence*: for a solid neighbor, reflect the wall-normal velocity component
    so **net flux through the wall = 0**. This is what makes milk glide along the
    rim and curl back inward instead of vanishing.
  - *Pressure (Jacobi)*: solid neighbor → Neumann (`dp/dn = 0`), i.e. substitute
    the center cell's pressure for the solid neighbor. Solid cells excluded from
    the solve.
  - *Gradient subtract*: use center pressure for solid neighbors so no gradient
    pushes fluid through the wall; force velocity = 0 in solid cells.
  - Start with **free-slip**; expose a `wallDrag` knob to blend toward no-slip
    (a little drag near the rim actually reads as realistic).

- **Why free-slip over just masking:** the pattern (rosetta/tulip) depends on milk
  hitting the far wall and folding back. Only a real wall boundary produces that
  fold; masking cannot.

### 4.3 Cup pose from the camera
The cup isn't centered or a perfect circle on screen (see reference images — it's
tilted, off-center). `CupDetector` provides an **ellipse** (center, semi-axes,
rotation) in view space. The compositor maps the circular sim grid → that ellipse
so the overlay sits in the real cup. The solver stays in its clean normalized
circle; the *view transform* handles perspective.

---

## 5. FOCUS B — Liquid level tracking (both models)

### 5.1 Fullness scalar (drives app logic) — primary
- `fillLevel: Float` in `0...1`, owned by `LevelModel`.
- Each frame during **FillCup**, integrate incoming flow:
  `fillLevel += flowRate * dt / cupVolume` (clamped to 1).
- `flowRate` comes from `PourSample` — estimated from surface-disturbance
  intensity + jug tilt (§6), **not** stream thickness (the water stream is
  invisible). No pour → no rise.
- Transitions:
  - `fillLevel ≥ fillThreshold (e.g. 0.85)` → **ReadyForFoam**.
  - Overshoot (`≥ ~0.98`) → "cup is full / overflowing" warning.
- Visualized as a rim ring that fills clockwise + crema color deepening as it fills.

### 5.2 Light height field (surface realism) — secondary
- A per-cell `height` texture (R16F), advected by the same velocity field.
- Pour adds a small local bump at the landing point (the dimple you see when a
  stream hits the surface); it relaxes/diffuses outward each frame.
- **Not** a full free-surface solver — it's a cosmetic displacement used only for
  shading: compute a normal from `height`, add a specular/rim highlight so the
  surface looks like moving liquid, not a flat decal.
- Cheap: one advect + one diffuse pass on a single-channel texture.

### 5.3 What "level" means visually from top-down
Straight-down, surface area is ~constant, so we don't literally see it rise. Level
therefore reads through: (a) the rim fill ring, (b) crema darkening toward full,
(c) the height field giving the surface motion/thickness. The scalar is the source
of truth; the visuals are its expression.

---

## 6. Perception — Vision-tracked pour (ARKit + Vision)

- **ARSessionManager** — `ARKit` world/face-off session for a stable overhead
  camera texture + lighting; provides the pixel buffer to Vision and Metal.
- **CupDetector** — find the cup rim each frame (or lock on once, then track):
  - Candidate approach: contour / ellipse detection (Vision
    `VNDetectContoursRequest` → fit ellipse) or a small trained detector. Output:
    cup ellipse (center, axes, angle) + confidence. Smoothed over time.
- **PourTracker** — find where the pour lands and how strong it is. Because the
  liquid is **clear water** (§1.1), we do *not* track the stream by its color.
  Instead combine two robust cues:
  1. **Jug/spout tracking (primary).** Detect the jug and its spout tip above the
     cup (the jug is an opaque, high-contrast object — see reference clips).
     Project straight down from the spout tip to the cup surface → **landing
     point** in cup-normalized UV. The spout's tilt/height also proxies flow.
  2. **Surface-disturbance tracking (confirm + refine).** Where water hits, it
     makes ripples / a moving dimple / specular glints. Detect that disturbed
     region (frame differencing + optical flow on the cup interior) to confirm the
     landing point and estimate intensity even when the spout is occluded by a hand.
  - **Landing point** = fused spout-projection + disturbance centroid.
  - **flowRate** ≈ disturbance area/intensity (and jug tilt), *not* stream width.
  - **velocity** ≈ landing-point motion between frames.
  - Emit `PourSample { uv, velocity, flowRate, t }` per frame; absent when no
    disturbance and spout is away from the cup.
- **Fallback `PourSource`**: a `TouchPourSource` produces the same `PourSample`s
  from finger drags so simulation and patterns can be built and tuned before
  Vision is reliable. Both conform to `protocol PourSource`.

Risks: with clear water there is **no stream to segment**, so tracking leans
entirely on the jug pose + surface disturbance — both can be noisy or occluded by
the hand. Mitigate with sensor fusion of the two cues, heavy temporal smoothing,
a "tap to confirm cup" manual override, and the touch fallback. If jug tracking
proves unreliable, a **dyed water** option (a drop of food coloring) is a cheap
physical fallback that makes the stream trackable without changing any code path.

---

## 7. AR overlay rendering

- **Compositor (MTKView)** draws in order:
  1. Camera background (full-screen textured quad from the AR pixel buffer).
  2. Fluid overlay — sim texture rendered with `renderCremaMasked` style output
     (α = 0 outside cup, feathered rim) warped from the sim's normalized circle to
     the detected cup ellipse. Blended over the camera.
  3. Guidance layer (CoreGraphics / SwiftUI Canvas): target pour path, direction
     arrows, current pour dot, ✅/❌ status.
- The fluid's alpha mask + ellipse warp is what makes it look like it's *in* the
  real cup rather than pasted on top.

---

## 8. Pattern guidance & scoring (FormArt)

Each pattern = a scripted **pour choreography**: a sequence of
`PourStep { targetUV, direction, duration, note }` (derived from the reference
clips — e.g. rosetta = pour high in far center, wiggle back while dragging toward
the near rim; heart = steady center pour then a fast pull-through).

- **Guidance**: render the current step's target point + direction arrow over the
  cup. Advance steps on completion.
- **Live feedback**: compare the tracked pour (`PourSample`) against the current
  step's target/direction each frame → **on-track** (within tolerance) or
  **missed** (❌ pulse). This is the app's "are you following the pattern" logic.
- **Milk injection**: at the tracked pour UV, splat milk dye + velocity into the
  solver (existing `splat` kernel). The contained fluid drags it into shape.
- **Scoring**: at the end, compare the milk-dye texture to the ideal pattern
  template (normalized cross-correlation / IoU of the white regions) → 0–100 score.

Patterns are data, not code, so tulip/heart/rosetta are just different
`[PourStep]` arrays + templates; new patterns are added without touching the solver.

---

## 9. Data types (sketch)

```swift
struct PourSample { var uv: SIMD2<Float>; var velocity: SIMD2<Float>
                    var flowRate: Float;  var t: TimeInterval }

protocol PourSource { var samples: AsyncStream<PourSample> { get } }   // Vision or Touch

struct CupPose { var center: SIMD2<Float>; var axes: SIMD2<Float>; var angle: Float }

enum Phase { case setup, patternSelect, fillCup, readyForFoam, formArt, result }

final class LevelModel {         // FOCUS B
    private(set) var fillLevel: Float          // 0...1 fullness scalar
    let heightTexture: MTLTexture              // light surface field
    func ingest(_ s: PourSample, dt: Float)
}

final class FluidSimulation {    // FOCUS A
    var cup: CupPose                           // solver boundary
    func splat(_ s: PourSample)                // milk/velocity injection
    func step(dt: Float)                       // contained solve + height advect
    var outputTexture: MTLTexture              // α-masked crema/milk render
}
```

---

## 10. Build milestones

1. **M1 — Contained solver (FOCUS A).** Add cup boundary to `Fluid.metal`
   (free-slip walls). Drive with `TouchPourSource`. Verify: dye stays in the cup,
   swirls off the rim, no corner leakage. *Pure simulated cup, no camera yet.*
2. **M2 — Level model (FOCUS B).** Add fullness scalar + fill→foam transition +
   rim-ring visual; add the light height field + surface shading.
3. **M3 — Pattern engine.** `PourStep` choreographies for heart/tulip/rosetta,
   guidance overlay, on-track/missed feedback, end scoring — still on touch input.
4. **M4 — Perception.** ARSession + CupDetector (ellipse) + AR compositor:
   fluid warped into the real cup on the live feed.
5. **M5 — Vision pour tracking.** Replace `TouchPourSource` with the real
   milk-stream tracker behind the same `PourSource` interface. Tune, smooth,
   add manual overrides.
6. **M6 — Flow + polish.** Full phase state machine, setup/instruction screens,
   result screen, haptics/sound.

Each milestone is runnable on its own; M1–M2 are the two things flagged as missing.

---

## 11. Open questions / risks

- **Cup detection robustness** under varied lighting / cup colors — may need a
  manual "tap the rim" calibration as ground truth.
- **Pouring clear water** is the biggest CV unknown — there is no visible stream,
  so tracking depends on jug pose + surface disturbance (§6). Touch fallback keeps
  the rest of the app unblocked; dyed water is a physical escape hatch.
- **Solver stability** at free-slip walls — validate no pressure blow-up at the
  boundary; clamp velocities; tune Jacobi iteration count (~20–40).
- **Perspective**: the cup is an ellipse, not a circle, on screen — the sim↔view
  warp must track it or the overlay drifts off the real rim.
- **Coordinate spaces**: define one cup-normalized UV space early; every module
  (perception, sim, guidance) speaks it, and only the compositor knows pixels.

---

## 12. Immediate next step
Build **M1**: extend `Fluid.metal` with the cup solid boundary and a
`TouchPourSource` harness, in a pure simulated cup, to prove containment before
any camera work. Nothing else in the plan is blocked by it.

---

## 13. Foreground occlusion — real jug over simulated coffee

### 13.1 Goal
The coffee is locked inside the cup, but must read as if it is physically *in*
the cup: when the real **pitcher, hand, or falling stream** passes over the cup,
that real object appears **on top of** the simulated coffee, with the cup and
table visible underneath. Today the coffee is a solid disc painted over the
camera, so anything real that crosses the cup is hidden *behind* the fake coffee
— which breaks the illusion.

### 13.2 The decision, per pixel
For every pixel inside the cup, choose one of:
- **Cup surface** → draw the **simulated coffee**.
- **Something in front of the cup** (jug / hand / stream) → show the **live
  camera** so the real object occludes the coffee.

So the coffee needs a *foreground mask*: draw coffee only where the live view
still looks like the empty cup; elsewhere inside the cup, let the camera through.

### 13.3 Primary method — reference background subtraction
The cup surface is nearly static (clear water in a fixed cup on a tripod), so the
empty cup is a stable "background". Anything new over it is foreground.

1. **Capture a reference frame at acquisition.** When the user taps to place the
   cup (cup is empty, camera still), snapshot the current camera frame into a
   `referenceTexture`.
2. **Per-frame difference inside the cup.** `diff = distance(cameraRGB, referenceRGB)`.
   - `diff` small → surface unchanged → **coffee**.
   - `diff` large → object in front → **camera** (real jug shows through).
3. **Soft + stable.** `foreground = smoothstep(t0, t1, diff)`; the coffee's alpha
   is multiplied by `(1 - foreground)`. Add light temporal smoothing so edges
   don't shimmer.

This handles the jug, the hand, AND the real pouring stream uniformly, with no
model of what the object is.

### 13.4 Rendering change
Replace the current two draws (camera fullscreen, then coffee disc over it) with
**one compositor pass** so occlusion is decided per pixel:

```
// fullscreen fragment
camUV   = aspectFill(screenUV)
camRGB  = camera.sample(camUV)
cupUV   = pose.viewToCupUV(screenUV)          // inverse ellipse warp
if (inside cup circle at cupUV) {
    coffee = fluid.sample(cupUV)              // rgb + cup-mask alpha
    refRGB = reference.sample(camUV)
    fg     = smoothstep(t0, t1, distance(camRGB, refRGB))
    a      = coffee.a * (1 - fg)              // hide coffee where foreground
    out    = mix(camRGB, coffee.rgb, a)
} else {
    out = camRGB
}
```

Needs, bound to that pass: camera texture, reference texture, fluid texture, the
cup pose (center/axes/angle), and the camera aspect-fill transform.

### 13.5 Enhancements (optional, device-dependent)
- **Depth occlusion (LiDAR / dual-camera devices).** With `AVCaptureDepthDataOutput`
  or ARKit `sceneDepth`, foreground = anything **closer than the cup plane**. This
  is the most robust cue and is immune to lighting/shadow; use it when available
  and fall back to §13.3 otherwise.
- **Hand segmentation.** Vision `VNGeneratePersonSegmentationRequest` reliably
  masks the hand/arm; OR it with the subtraction mask for a cleaner hand edge.

### 13.6 Edge cases & mitigations
- **Shadows** the jug casts on the cup differ from the reference → could be read
  as foreground. Use a **chroma / luma-normalized** difference so shadows (same
  hue, lower brightness) are discounted.
- **Lighting drift / slight camera bump** makes the whole cup differ from the
  reference → coffee flickers off. Mitigate with a slow **EMA update of the
  reference** in regions that stay static, plus a manual **re-capture** control.
- **Jug the same colour as the cup** (white on white) → weak diff in flat areas;
  edges and texture still trigger. Depth path removes this issue entirely.

### 13.7 Build steps
1. Snapshot `referenceTexture` on tap acquisition (and on manual re-capture).
2. Add a unified compositor fragment (camera + masked coffee) replacing the
   separate camera and fluid blits; pass pose, aspect transform, thresholds.
3. Tune `t0/t1` and add temporal smoothing against real footage.
4. (Optional) add the depth path with graceful fallback; OR-in hand segmentation.

### 13.8 Decision (locked)
Target device **has LiDAR** → build the **depth path** as primary. Capture
synchronized video + depth (`AVCaptureDataOutputSynchronizer` on the
`.builtInLiDARDepthCamera`), sample the cup-surface depth at tap acquisition, and
in the compositor mask the coffee wherever the depth is **closer than the cup
plane minus a margin** — so the jug/hand/stream occlude the coffee. Reference
subtraction (§13.3) remains the documented fallback for non-LiDAR devices.
```
