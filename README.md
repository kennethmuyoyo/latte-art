# Latte Art Generation: Tech Report & README

## App Concept

An iOS app that utilizes MetalKit, Vision, CoreGraphics, and ARKit to calculate physical movement, simulate & render latte art, and showcase patterns for users to follow in real-time. The user uses real water, a pitcher, and a cup, while the phone (on a tripod) simulates the milk/coffee physics on screen.

### The Flow

1. Setup instructions (tripod, fill jug with water).
2. User selects a pattern (Tulip, Heart, Rosetta).
3. AR overlay/UI shows where to pour.
4. User pours water; Metal framework simulates the milk reacting with the coffee base.
5. The simulation tracks two phases: **Mixing** (base) and **Drawing** (foam) based on pour height.
6. Real-time visual feedback indicates if the pour is on track or missing the pattern.

### Present Your Team

Adit - UX/UI and Domain Knowledge
Charisa - UX/UX design
Samuel - Simulation Layer
Elliezer - Presentation LAyer
Ken - Sensor Layer
---

## Starting Assumption

**What did we assume, before any real exploration (start of investigation phase)?**

We assumed we would use ARKit's newest `trackingObjects` API and Create ML's "Extended Training" mode to directly track the physical stainless steel pitcher and the ceramic cup.

**Because:** It sounded like the most native, advanced Apple way to solve the problem. Apple showcased 3D object tracking at WWDC, and we assumed that by feeding a 3D model of our pitcher into Create ML, ARKit would magically know its position, tilt, and height, which we could then feed into our Metal physics simulation.

---

## The Exploration Log

### What we browsed, and what surprised us

- We browsed WWDC26 sessions on object tracking and spatial accessories.
- We were surprised to learn that the new `trackingObjects` API is locked behind an iOS 27 Beta, which makes it incredibly risky for a production app.
- We also discovered that training a single object in Create ML takes 10 to 16 hours.

### What we actually built or tested in code (not just read about)

- Investigated ARKit's ability to track objects using standard feature extraction.
- Looked into the math required for fiducial markers (AprilTags) using Swift wrappers for a C-based Vision processing pipeline.

### What we discovered that we didn't expect

- **The Reflection Problem:** Computer vision SLAM algorithms fundamentally fail on reflective surfaces. A shiny stainless steel milk pitcher reflects the room around it. As the pitcher moves, the "features" (reflections) move, causing ML models to instantly lose track of the object.
- **The Liquid Tracking Problem:** Standard LiDAR/depth mapping passes straight through transparent water, meaning ARKit cannot natively tell us where the surface of the liquid is inside the cup.

---

## What We Tried and Dropped

**We considered:** Create ML Extended Training for 3D Object Tracking (the iOS Beta API).

**We dropped it because:**
- It relies on unstable Beta OS features.
- It completely fails on shiny metal pitchers.
- The computational overhead is completely unnecessary. We realized we don't need a heavy machine learning model to "guess" the orientation of a pitcher; we just need precise geometric data.

**We considered:** Vision Hand Pose Tracking (`VNDetectHumanHandPoseRequest`).

**We dropped it because:** Hand tracking infers the spout's location through an unknown grip, which adds a highly variable error term. A hand grip changes drastically from person to person (and pour to pour). We need to rigidly track the object itself, not infer its position through a noisy proxy.

---

## Real Limitations Hit

**The Situation:** We had no reliable way to track the spout of a shiny metal pitcher or the dynamic water level inside a moving cup without the app crashing or losing the AR anchor.

**How we worked around it (The AprilTag Pivot):** We abandoned ML object tracking entirely and engineered a robust, math-driven architecture using AprilTags (Fiducial Markers) processed via the Vision framework.

### For the Pitcher

We placed 2 AprilTags (one at the spout, one on the opposite back side).

**The Math:** The distance between these two tags in 3D space gives us the exact tilt of the pitcher, which dictates the pour intensity. By calculating the pixel size of the tags relative to the camera, we determine the Z-height of the pitcher relative to the cup, accurately triggering the phase shift in our Metal simulation (High pour = Mixing phase, Low pour = Foam Drawing phase).

*Implementation note:* the pixel-size-vs-camera heuristic above was superseded during implementation — AprilTag pose estimation already yields true 3D translation for each tag, so pour height is computed directly as the spout tag's signed distance above the cup's detected plane, which is simpler and more accurate than a pixel-size proxy.

**Occlusion Risk:** We acknowledge the spout tag will likely get wet or occluded by the liquid stream/hands during a real pour. The two-tag system provides a fallback if one is occluded, but testing this occlusion threshold is our first physical testing priority.

### For the Cup

We placed 3 AprilTags on the rim/base.

**The Math:** The distance between the two opposite tags gives us the diameter of the simulation boundary. The third tag allows us to triangulate the exact radius and 3D plane of the water's surface, solving the LiDAR transparency issue.

By applying the geometric circumcircle formula to the (X,Y,Z) coordinates of the three tags, we calculate the exact center and radius of the cup. Furthermore, the cross-product of these three points yields the normal vector of the cup's opening. By cross-referencing this plane with the iPhone's absolute gravity vector (via the IMU), we can mathematically calculate and render the horizontal water plane as the cup tilts, completely bypassing the need for depth-sensing hardware.

---

## The Revised Decision

**Final decision:** We are using the Vision Framework combined with an AprilTag C-Library Swift Wrapper for pose estimation, feeding that geometric data directly into MetalKit for the fluid simulation, and rendering the UI guides with CoreGraphics. ARKit is used strictly to provide stable camera intrinsics and world-space alignment.

*Implementation note:* in the shipped implementation, tag detection runs directly against ARKit's captured pixel buffer via the `SwiftAprilTag` wrapper rather than through a `VNRequest` — the Vision framework itself isn't directly invoked. "Vision framework" above describes the conceptual sensor-layer role (turning camera pixels into geometric data), not a literal `import Vision` dependency.

**What changed since Section 1, and why:** We moved from a "Black Box ML" approach to a "Deterministic Geometry" approach. Apple's 3D object tracking sounded great, but physical reality (shiny metal) made it impossible. AprilTags provide instant, zero-training, robust 6DoF tracking that is entirely sufficient for pour-mechanics feedback.

**The Dependency Trade-Off:** We consciously traded an "unreleased Beta OS dependency" for a "third-party C-library dependency" (the AprilRobotics C library wrapped into Swift). This is a strategic win: we depend on a mature, stable, open-source library that runs flawlessly on current, stable iOS versions rather than waiting on experimental frameworks that may break our app.

---

## App Track Addendum

### About the Frameworks

**Does your use case genuinely need both frameworks working together, or could it work with just your main one?**

Yes. The Vision framework (processing the AprilTags) acts as the "sensor" layer. It only provides numbers (XYZ coordinates and tilt angles). MetalKit is entirely responsible for the "physics and rendering" layer. Vision cannot simulate fluid dynamics, and Metal cannot read camera pixels to find a pitcher. They must operate together in a highly synchronized pipeline.

### About Accessibility and Localization

**What did you decide to support, what did you decide not to, and why?**

We decided to localized the setup instructions into English since coffee is universal. We relied on high-contrast CoreGraphics arrows for visual guidance to assist users with varying visual acuities, though auditory feedback for pour speed is currently out of scope. 

### About Privacy

**What data does your app actually need? What happens in your app when the user says no to a permission?**

The app absolutely requires Camera access to track the AprilTags and run the AR session. If the user denies camera permission, the app fundamentally cannot function. We handle this by displaying a dedicated onboarding screen explaining why the camera is needed. No video feeds or images are ever recorded, saved, or sent off-device; all Vision processing happens strictly locally in real-time.

---

## Annex: Team Roles & Responsibilities

To execute this architecture effectively, our 3-person team is divided across the three core technical layers of the application:

### 1. Vision & Tracking Engineer (The Sensor Layer)

**Responsibilities:** Integrating the AprilTag C-Library wrapper into the Swift project, bridging the C code, managing the ARKit world-tracking session, and processing the Vision framework pixel buffers. Must accurately pass camera intrinsics (`camera.intrinsics` from ARKit) to the tag detector to ensure correct pose math.

**Key Deliverables:** A real-time, 60FPS data stream of 6DOF (Degrees of Freedom) coordinates for both the pitcher spout and the cup. Responsible for executing the circumcircle and gravity-vector math to locate the dynamic water plane.

### 2. Metal & Physics Engineer (The Simulation Layer)

**Responsibilities:** Building the GPU-accelerated fluid dynamics engine using MetalKit.

**Key Deliverables:** A highly optimized particle or fluid simulation that reacts to the XYZ coordinates and tilt data provided by the Tracking Engineer. Must implement the core physics logic for the latte art mechanics: shifting between the "Mixing Phase" (particles plunging deep) and the "Drawing Phase" (foam resting on the surface) based strictly on pour height and speed.

### 3. UI/UX & CoreGraphics Developer (The Presentation Layer)

**Responsibilities:** Translating the provided app design into functional frontend code (SwiftUI/UIKit), managing the app's state flow (Setup → Pattern Selection → Pouring → Results), and building the 2D overlays.

**Key Deliverables:** The user-facing app shell, onboardings, and the CoreGraphics visual guides (e.g., drawing the target arrows for the Tulip, Heart, and Rosetta patterns on the screen). Responsible for the real-time visual feedback logic that tells the user if they are successfully following the target pattern or drifting off-path.
