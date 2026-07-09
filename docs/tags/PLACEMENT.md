# AprilTag printing & placement

Physical setup for the sensor rig: 3 tags on the cup, 3 on the pitcher, all `tag36h11`, all **14 mm** per side (the outer black border — see below).

**Minimal pitcher option:** the pitcher's 2 tilt-reference tags (11, 12) are not both required — `AprilTagRoles.pitcherReferenceIDs` is a list the code picks from opportunistically, using whichever of them is actually detected and falling back gracefully if neither is. If you only want to print and mount ONE reference tag (spout + 1 = 2 tags total on the pitcher instead of 3), that's fully supported with no code changes — see "Pitcher placement" below for which position to use.

## What to print

Print [`print_sheet.pdf`](print_sheet.pdf) at **100% / Actual Size** (PDF viewers default to this — avoid any "fit to page"/"shrink to fit" option). It's a full **A4 page** (210×297&nbsp;mm, baked directly into the PDF's page geometry — not just image metadata a print dialog can silently ignore) tiled edge-to-edge with **81 tags**: 9 columns × 9 rows, one ID per row (repeating 0, 1, 2, 10, 11, 12, 0, 1, 2). Cut out a whole row and you have a stack of identical, ready-to-mount spares for that ID — useful since tags do get lost, wet, or miscut. [`print_sheet.png`](print_sheet.png) (same layout, 406.4 DPI) is provided as a raster fallback. Individual single-tag files are also available: [`tag_0.png`](tag_0.png), [`tag_1.png`](tag_1.png), [`tag_2.png`](tag_2.png), [`tag_10.png`](tag_10.png), [`tag_11.png`](tag_11.png), [`tag_12.png`](tag_12.png).

After printing, **measure the verification ruler printed at the top of the sheet**. It must measure exactly 60 mm.
- If it does: cross-check against the magenta-outlined tile (top-left of the grid) — it should be 14 mm per side. You're set; `AprilTagRoles.cupTagSizeMeters` / `pitcherTagSizeMeters` in `LatteArt/Sensor/AprilTagTracker.swift` are already `0.014` and need no change.
- If it doesn't (e.g. your printer rescaled to fit the page): compute `measured_ruler_mm / 60 × 14 mm` — that's your actual printed tag size in mm. Convert to meters and set both `AprilTagRoles.cupTagSizeMeters` and `pitcherTagSizeMeters` to that value.

**The dimension that matters is the outer black-border square only** (bounded by the magenta or gray cut-guide, depending on the tile) — not the white margin around it. This matches `SwiftAprilTag`'s documented `tagSize` semantics exactly (`Detection.estimatePose`'s doc comment: "physical edge length of the tag's outer black border... NOT the full tag image including any white margin").

Mount each tag flat, uncurled, and matte if possible (glossy laminate can glare and wash out the black/white contrast under strong light). At 14 mm, cut carefully and along the gray guide lines — there's very little margin for a crooked cut.

## Tag → ID map

| Tag ID | Family | Role | Mounts on |
|---|---|---|---|
| 0, 1, 2 | tag36h11 | Cup rim (×3) | Cup, outside wall, evenly spaced |
| 10 | tag36h11 | Pitcher spout | Pitcher, side nearest the spout |
| 11 | tag36h11 | Pitcher tilt reference (side, 90°) | Pitcher, 90° around from the spout |
| 12 | tag36h11 | Pitcher tilt reference (opposite, 180°) | Pitcher, directly opposite the spout |

These IDs are hardcoded in `AprilTagRoles` (`LatteArt/Sensor/AprilTagTracker.swift`) — if you print different IDs, update the code to match, not the other way around.

## Cup placement (3 tags — IDs 0, 1, 2)

![Reference: tag positions on a cup, viewed from above](cup_placement_reference.png)

*Reference composite built on a stock photo, for illustrating angular position only — swap in a photo of the actual cup once available.*

- Mount all 3 tags on the **outside** wall of the cup, spaced **evenly around the circumference** (roughly 120° apart — exact spacing doesn't matter, but avoid clustering all 3 on one side, which makes the circumcircle math (`CupGeometry.fromCupTags`) numerically unstable).
- Align each tag so its **horizontal centerline sits level with the cup's rim** (the top edge) — e.g. the tag straddles the rim, half above/half below. This matters: the app treats the plane through the 3 tags' centers as "the rim plane" and measures pitcher pour-height relative to it (`heightAboveRimMeters`). If the tags are mounted well below the rim instead, every height reading will carry a constant offset.
- Face each tag outward (flat against the cup's side wall, normal pointing away from the cup), so it's visible to a phone camera positioned above/in front of the cup during a pour.
- ID order doesn't matter functionally (the code reads all 3 by ID, not position) — but for your own sanity when debugging, a natural convention is ID 0 facing the camera's default position, 1 and 2 spaced clockwise from it.
- **The circle survives losing 1 or even 2 of these 3 tags to occlusion** once all 3 have been seen together at least once (`CupRegistration` caches their fixed relationship to the cup's center/radius/plane the moment that happens, and reconstructs from whichever single tag is visible afterward). It cannot recover if all 3 are hidden simultaneously — there's nothing left to reconstruct from — but a hand or the pitcher briefly covering one or two tags is no longer fatal.

## Pitcher placement (3 tags — IDs 10, 11, 12)

![Reference: tag positions on a pitcher, side view](pitcher_placement_reference.png)

*Reference composite built on a stock photo — swap in a photo of the actual pitcher once available; it shows the original 2-tag (10/11) layout, drawn before tag 12 was added — mount 12 per the instructions below, directly opposite 10.*

- **ID 10 (spout)**: mount on the flat face of the pitcher closest to the spout. Required — its position fixes the pour's landing point on the cup and is used for the depth test that lets the pitcher occlude the rendered fluid surface. If this tag is hidden, there is no pour that frame, full stop.
- **Only printing one reference tag?** Skip 11 and print just 12, mounted **directly opposite the spout (180°)** — that position alone gives the strongest signal (see why below), and the code works fine with only one reference tag present (it just uses whatever's visible). 2 tags total on the pitcher (spout + this one) is a fully supported setup, not a stopgap.
- **ID 11 (side, 90°)**: mount roughly 90° around the pitcher body from the spout. This is a **secondary, weaker** tilt reference, only worth adding as a fallback for when 12 gets occluded — see why below.
- **ID 12 (opposite, 180°)**: mount **directly opposite the spout tag**, at the same height. This is the **preferred** tilt reference whenever it's visible.
- **Why 180° beats 90° for tilt, concretely:** tilt is read from how far the vector between the spout tag and a reference tag has rotated away from horizontal (`AprilTagPourSource.tilt`). As the pitcher tips to pour, it rotates about an axis roughly perpendicular to the pour direction — so a reference tag mounted ALONG the pour direction (opposite the spout) sweeps the most vertically for a given tilt, while one mounted 90° around (off to the side, closer to the rotation axis itself) sweeps much less. Less vertical sweep per degree of real tilt means a weaker signal, and the same absolute tag-position noise turns into a *larger* angular error over that shorter effective baseline. This — not a calibration problem — is almost certainly why tilt felt unreliable with only the 90° tag available. The code automatically prefers whichever visible reference tag is farthest from the spout (on a round pitcher, farthest-from-spout ≈ closest-to-opposite), so once 12 is mounted it becomes the default reference and 11 only kicks in as a fallback when 12 is occluded.
- **Height — as high on the body as the tag will sit flat, and the SAME height for all 3.** `AprilTagPourSource` uses the spout tag's own 3D position directly as the pour-height measurement (`cup.heightAbovePlane(spout)`) — it doesn't know where the physical spout tip is relative to the tag, so whatever vertical gap exists between the tag and the actual spout tip becomes a constant error in every height reading. Minimize that gap: **starting from the rim, slide each tag down the body until the whole square sits flat against the wall** (not bent over the curved shoulder just below the rim) — that's the mounting spot. On most pitchers this lands each tag's top edge a few mm to ~1–2 cm below where the rim's curve ends and the straight wall begins.
  - This leaves a small (roughly one tag-height, ~1.5–2 cm) built-in offset between the spout tag and the true spout tip — acceptable relative to typical pour heights (several cm), and not something to over-engineer by hand-measuring; if it turns out to matter, add a fixed calibration constant in `AprilTagPourSource` once you've measured your specific pitcher, rather than chasing sub-mm placement.
- **Critical: all 3 pitcher tags must be at the exact same height.** Any height mismatch between the spout and whichever reference tag is active reads as a constant fake "resting tilt" even when you're holding the pitcher level. Mount all 3 by the same "slide down from the rim until flat" procedure so they land level with each other, even if the rim itself isn't perfectly level all the way around.
- If the handle attachment blocks the exact opposite point for tag 12, shift it a little to either side — exact 180° isn't required, just as close to opposite as the handle allows and at the same height as the other two.

## Known risk: occlusion during a real pour

The spout tag is the one most likely to get wet or blocked by the liquid stream or your hand mid-pour. `AprilTagPourSource` has a 150 ms grace period so a single dropped frame doesn't kill the pour, but sustained occlusion (tag fully wet, or your hand covering it for longer than that) will stop the pour signal entirely — there's no fallback for a hidden spout tag, unlike the tilt-reference tags. This is a known, not-yet-solved risk — flagged in the Sensor issue on GitHub as a priority to test once tags are physically mounted.

## Known limitation: occlusion is tag-based, not general-purpose

The fluid surface only gets occluded (real pitcher shows through instead of the virtual disc) where a *tracked pitcher tag* is genuinely closer to the camera than the cup surface — a real depth test using the tag's own known position, not a guess. It does **not** occlude for hands, spoons, or anything else without a tag on it: a single camera has no way to know an untagged object's distance without either a depth sensor (LiDAR, hardware-gated to Pro-model devices) or a trained ML segmentation model (e.g. Apple's People Occlusion, hand/body-specific). Neither is implemented yet — revisit if this turns out to matter in practice.
