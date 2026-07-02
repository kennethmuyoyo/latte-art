import CoreVideo
import simd
import QuartzCore

/// Tracks the **pour itself** — the water falling from the jug — and uses where
/// that stream lands as the anchor for the sim (spec §6). The stream is the
/// signal, not the cup surface: this deliberately does NOT trigger on generic
/// surface ripple or camera vibration, which was the earlier failure mode.
///
/// How it works each frame:
///  1. Downscale the whole frame to a luminance grid and frame-difference it to
///     get a motion field (the falling water and the moving jug show up here).
///  2. A pour stream is a *tall, narrow, vertical* run of motion descending into
///     the cup. We find the column with the longest continuous vertical motion
///     run and require it to be (a) tall enough and (b) clearly taller than the
///     typical column — so a spread-out ripple or a global lighting change, which
///     have no dominant vertical column, are rejected.
///  3. The bottom of that run — where the stream meets the surface — is the
///     landing anchor, mapped into cup-UV. Its motion magnitude gives flow.
///  4. The stream must persist a couple of frames before it counts, and drop-outs
///     clear it, so brief noise can't fire a pour.
///
/// Conforms to `PourSource`, so it drives the sim like touch does.
final class WaterPourTracker: PourSource {
    private(set) var current: PourSample?
    var onSample: ((PourSample) -> Void)?

    // Motion grid over the full frame (portrait-ish).
    private let gw = 48
    private let gh = 64

    // Tunables (calibrate against real footage).
    /// Per-cell luminance change (0..1) to count as motion.
    var motionThreshold: Float = 0.05
    /// Minimum vertical run height, as a fraction of the grid, to be a stream.
    var minRunFraction: Float = 0.16
    /// How much taller the stream column must be than the average active column.
    var localityFactor: Float = 1.8
    /// Divisor mapping stream motion magnitude to a 0..1 flow rate.
    var flowScale: Float = 8.0
    /// Consecutive qualifying frames before a pour is emitted.
    var minStreak = 2

    private var active = false
    private var prev: [Float]?
    private var streak = 0
    private var prevLanding: SIMD2<Float>?
    private var prevTime: TimeInterval?

    func start() { active = true }
    func stop() {
        active = false; prev = nil; streak = 0
        prevLanding = nil; current = nil
    }

    /// Process a frame. `pose` maps view-normalized coordinates to the cup so the
    /// landing point can be expressed in cup-UV.
    func process(pixelBuffer: CVPixelBuffer, pose: CupPose) {
        guard active else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        // 1. Luminance grid over the whole frame.
        var lum = [Float](repeating: 0, count: gw * gh)
        for gy in 0..<gh {
            for gx in 0..<gw {
                let vx = (Float(gx) + 0.5) / Float(gw)
                let vy = (Float(gy) + 0.5) / Float(gh)
                let px = min(width - 1, Int(vx * Float(width)))
                let py = min(height - 1, Int(vy * Float(height)))
                let o = py * rowBytes + px * 4
                let b = Float(ptr[o]), g = Float(ptr[o + 1]), r = Float(ptr[o + 2])
                lum[gy * gw + gx] = (0.299 * r + 0.587 * g + 0.114 * b) / 255
            }
        }

        defer { prev = lum }
        guard let previous = prev else { return }

        // 2. Longest vertical motion run per column.
        var bestCol = -1
        var bestRun = 0
        var bestBottom = 0
        var bestMag: Float = 0
        var runSum = 0
        var runCount = 0
        for gx in 0..<gw {
            var run = 0, mag: Float = 0
            var colBestRun = 0, colBottom = 0, colMag: Float = 0
            for gy in 0..<gh {
                let idx = gy * gw + gx
                let d = abs(lum[idx] - previous[idx])
                if d > motionThreshold {
                    run += 1; mag += d
                    if run > colBestRun { colBestRun = run; colBottom = gy; colMag = mag }
                } else {
                    run = 0; mag = 0
                }
            }
            if colBestRun > 0 { runSum += colBestRun; runCount += 1 }
            if colBestRun > bestRun {
                bestRun = colBestRun; bestCol = gx; bestBottom = colBottom; bestMag = colMag
            }
        }

        // 3. Qualify the stream: tall enough, and clearly taller than typical.
        let minRun = Int(Float(gh) * minRunFraction)
        let avgRun = runCount > 0 ? Float(runSum) / Float(runCount) : 0
        let isStream = bestCol >= 0
            && bestRun >= minRun
            && Float(bestRun) >= localityFactor * avgRun

        let now = CACurrentMediaTime()
        guard isStream else {
            streak = 0; current = nil; prevLanding = nil
            return
        }
        streak += 1
        guard streak >= minStreak else { return }

        // 4. Landing anchor = bottom of the stream (where it meets the surface).
        let landView = SIMD2<Float>((Float(bestCol) + 0.5) / Float(gw),
                                    (Float(bestBottom) + 0.5) / Float(gh))
        let landingUV = CupSpace.clampToCup(pose.cupUV(fromViewPoint: landView))

        var velocity = SIMD2<Float>(0, 0)
        if let pl = prevLanding, let pt = prevTime {
            let dt = Float(max(now - pt, 1.0 / 120.0))
            velocity = (landingUV - pl) / dt
        }
        let flow = min(1, bestMag / flowScale)

        let sample = PourSample(uv: landingUV, velocity: velocity, flowRate: flow,
                                confidence: min(1, Float(bestRun) / Float(minRun * 2)),
                                time: now)
        current = sample
        prevLanding = landingUV
        prevTime = now
        onSample?(sample)
    }
}
