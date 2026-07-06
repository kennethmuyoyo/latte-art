// TEMPORARY dev harness — replaced by Presentation (Ellie). Kept only to
// exercise the Simulation layer end-to-end (touch / scripted pour → physics →
// fluid → render) before the real UI lands.

import SwiftUI
import QuartzCore
import simd

/// Owns the Metal stack and the sources for the lifetime of the debug view.
/// A plain object so SwiftUI re-renders don't rebuild the sim.
final class SimulationHarness: ObservableObject {
    let controller: SimulationController
    let blitter: FluidBlitter
    let touchSource = TouchPourSource()

    private var autoSource: AutoPourSource?
    private(set) var autoOn = false

    init?() {
        guard let ctx = MetalContext(),
              let sim = FluidSimulation(context: ctx),
              let blitter = FluidBlitter(context: ctx) else { return nil }
        let controller = SimulationController(sim: sim)
        blitter.controller = controller
        self.controller = controller
        self.blitter = blitter
        controller.attach(source: touchSource)
    }

    /// Attach the scripted circular pour (idempotent).
    func startAuto() {
        guard !autoOn else { return }
        autoOn = true
        let auto = AutoPourSource()
        autoSource = auto
        controller.attach(source: auto)
    }

    /// Toggle: scripted pour on ↔ back to touch.
    func toggleAuto() {
        if autoOn {
            autoOn = false
            autoSource = nil
            controller.attach(source: touchSource)
        } else {
            startAuto()
        }
    }

    func reset() { controller.requestReset() }
}

struct SimulationDebugView: View {
    // Force-unwrap: Metal is always available in the Simulator and on device;
    // if the stack can't build there's nothing this debug view can do anyway.
    @StateObject private var harness = SimulationHarness()!

    var body: some View {
        VStack(spacing: 16) {
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                SimulationView(blitter: harness.blitter)
                    .frame(width: side, height: side)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { g in
                                // gesture is local to the frame; normalize to the square
                                let originX = (geo.size.width - side) / 2
                                let originY = (geo.size.height - side) / 2
                                let nx = Float(min(max((g.location.x - originX) / side, 0), 1))
                                let ny = Float(min(max((g.location.y - originY) / side, 0), 1))
                                let uv = CupPose.centeredDefault.cupUV(fromViewPoint: SIMD2(nx, ny))
                                harness.touchSource.touchMoved(toUV: uv)
                            }
                            .onEnded { _ in harness.touchSource.end() }
                    )
            }
            .aspectRatio(1, contentMode: .fit)

            Readouts(controller: harness.controller)

            HStack(spacing: 20) {
                Button(harness.autoOn ? "Stop auto" : "Auto pour") { harness.toggleAuto() }
                    .buttonStyle(.borderedProminent)
                Button("Reset") { harness.reset() }
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .onAppear {
            // simctl cannot inject touches — this is the established headless
            // verification workaround: auto-start the scripted pour.
            if ProcessInfo.processInfo.environment["DEMO_POUR"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    harness.startAuto()
                }
            }
        }
    }
}

/// Observes the controller so the readouts refresh at the controller's ~12 Hz.
private struct Readouts: View {
    @ObservedObject var controller: SimulationController

    var body: some View {
        VStack(spacing: 4) {
            Text(String(format: "Fill: %.0f%%", controller.fillFraction * 100))
            Text("Phase: \(String(describing: controller.phase))")
            Text(String(format: "φ %.2f    Fr %.2f", controller.stats.phi, controller.stats.froude))
        }
        .font(.system(.body, design: .monospaced))
        .foregroundStyle(.primary)
    }
}
