import Foundation

/// All the pour physics as pure functions. No camera, no Metal, no state beyond
/// tunables — trivially testable. Physics decisions (the flow curve, the
/// float-vs-sink Froude gate) live HERE, not in Sensor: the sensor reports the
/// angle, never conclusions about the angle.
struct PourPhysics {
    // Placeholder Q(θ): linear from start angle to max. These are the former
    // AprilTagPourSource restAngle/maxAngle — flow-curve endpoints are physics
    // constants and live here; Sensor migration pending.
    var thetaStart: Float = 22 * .pi / 180
    var thetaMax: Float = 80 * .pi / 180
    var qMax: Float = 45             // realistic latte pour — a 220 ml cup should
                                     // take >10 s at moderate flow; 100 ml/s emptied
                                     // it in ~2.4 s. (Still a placeholder pending the
                                     // empirical Q(θ) calibration.)

    // stream
    var spoutArea: Float = 1.2e-4    // m², effective stream cross-section

    // float-vs-sink sigmoid, gated on the densimetric Froude number (external
    // physics review). Defaults anchored on the barista float (Fr≈5.4) / dive
    // (Fr≈9.4) canonical cases.
    var frCrit: Float = 7.4
    var k: Float = 1.0
    var gPrime: Float = 2.75         // m/s², g·Δρ/ρ: microfoam ~750 into coffee ~1010 kg/m³

    /// Placeholder weir flow, ml/s.
    func flow(tilt theta: Float) -> Float {
        let f = (theta - thetaStart) / (thetaMax - thetaStart)
        return qMax * min(max(f, 0), 1)
    }

    /// v_impact = sqrt(v_exit² + 2gH); v_exit from Q through the spout area.
    func vImpact(flow qMlPerSec: Float, height h: Float) -> Float {
        let q = qMlPerSec * 1e-6                  // → m³/s
        let vExit = q / spoutArea
        return (vExit * vExit + 2 * 9.81 * h).squareRoot()
    }

    /// Densimetric Froude number of the stream at impact. Penetration of a
    /// buoyant jet into a denser bath (a "fountain") is governed by Fr, not
    /// velocity alone — a fatter stream (higher Q) at the same v_impact dives
    /// deeper. The stream diameter comes from continuity (the stream necks
    /// down as it accelerates), so it introduces no new unknown.
    func froude(flow qMlPerSec: Float, vImpact v: Float) -> Float {
        guard qMlPerSec > 0, v > 0 else { return 0 }
        let q = qMlPerSec * 1e-6
        let d = (4 * q / (.pi * v)).squareRoot()
        return v / (gPrime * d).squareRoot()
    }

    /// φ ∈ [0,1]: 1 = milk floats (deposit white dye), 0 = punches under
    /// (canvas phase, momentum only). The soft middle gives snail trails free.
    func floatFraction(froude fr: Float) -> Float {
        1 / (1 + exp(-(frCrit - fr) / k))
    }

    // MARK: - Contract adapter

    /// The pour physics derived from one `PourSample`. φ is CONTINUOUS — never
    /// reduce float-vs-sink to a boolean.
    struct DerivedPour {
        var flowMlPerSec: Float
        var heightMeters: Float
        var vImpact: Float
        var froude: Float
        var phi: Float
    }

    /// The ONLY place that knows today's `PourSample` limitations. Maps the
    /// interim contract fields onto the physics inputs; the TODO(contract)
    /// notes mark what changes once the sensor ships raw measurements.
    func derive(from sample: PourSample, surfaceDepthBelowRim: Float) -> DerivedPour {
        // TODO(contract): when PourSample ships raw `tiltRadians`, compute
        // `flow(tilt:)` here instead of scaling the normalized flowRate.
        let q = sample.flowRate * qMax

        // TODO(contract): when PourSample ships `heightAboveRimMeters`, use
        // `heightAboveRimMeters + surfaceDepthBelowRim` directly.
        let base: Float
        switch sample.layingMilk {
        case .some(true):  base = 0.02   // laying milk in low & close
        case .some(false): base = 0.10   // pouring high
        case .none:        base = 0.04   // no opinion — moderate default
        }
        let h = base + surfaceDepthBelowRim

        let v = vImpact(flow: q, height: h)
        let fr = froude(flow: q, vImpact: v)
        let phi = floatFraction(froude: fr)
        return DerivedPour(flowMlPerSec: q, heightMeters: h, vImpact: v, froude: fr, phi: phi)
    }
}
