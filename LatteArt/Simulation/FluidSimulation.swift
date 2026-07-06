import Metal
import simd

/// One queued splat — the only way anything enters the sim.
struct Splat {
    var point: SIMD2<Float>       // sim UV, y-down
    var radius: Float             // uv units
    var dye: Float                // white amount to add (already × φ)
    var momentum: SIMD2<Float>    // cells/sec impulse along the stream direction
    var displacement: Float = 0   // divergence-source strength; foam volume deposition
}

/// 2D Stam Stable Fluids on Metal compute. Owns the velocity/dye/pressure
/// grids; knows nothing about pitchers, cameras, or physics upstream of the
/// queued splats. RealityKit/SwiftUI never touch these textures except to draw dye.
final class FluidSimulation {
    let device: MTLDevice
    let size: Int
    private(set) var dyeTexture: MTLTexture   // current front dye (display this)

    private var vel: (MTLTexture, MTLTexture)
    private var dye: (MTLTexture, MTLTexture)
    private var prs: (MTLTexture, MTLTexture)
    private var div: (MTLTexture, MTLTexture)

    private let pClear, pAdvect, pSplat, pDivergence, pDivSource, pJacobi, pSubtract, pDamp: MTLComputePipelineState

    private var pending: [Splat] = []
    private let jacobiIterations = 24
    private let velDissipation: Float = 1.0
    private let dyeDissipation: Float = 1.0
    // Per-frame at 60 fps ≈ 88%/s decay (foam/bottom-drag regime; the old
    // water-like 0.995 is why everything drifted).
    private let velocityDamping: Float = 0.965

    init?(context: MetalContext, size: Int = 256) {
        let device = context.device
        let lib = context.library
        func pipe(_ name: String) -> MTLComputePipelineState? {
            lib.makeFunction(name: name).flatMap { try? device.makeComputePipelineState(function: $0) }
        }
        guard let c = pipe("k_clear"), let a = pipe("k_advect"), let s = pipe("k_splat"),
              let d = pipe("k_divergence"), let ds = pipe("k_divergenceSource"),
              let j = pipe("k_jacobi"), let g = pipe("k_subtractGradient"),
              let dm = pipe("k_dampVelocity")
        else { return nil }
        (pClear, pAdvect, pSplat, pDivergence, pDivSource, pJacobi, pSubtract, pDamp) = (c, a, s, d, ds, j, g, dm)

        self.device = device
        self.size = size
        func tex() -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: size, height: size, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        guard let v0 = tex(), let v1 = tex(), let d0 = tex(), let d1 = tex(),
              let p0 = tex(), let p1 = tex(), let dv0 = tex(), let dv1 = tex() else { return nil }
        vel = (v0, v1); dye = (d0, d1); prs = (p0, p1); div = (dv0, dv1)
        dyeTexture = d0
    }

    func queue(_ splat: Splat) { pending.append(splat) }

    func reset(in cb: MTLCommandBuffer) {
        pending.removeAll()
        for t in [vel.0, vel.1, dye.0, dye.1, prs.0, prs.1, div.0, div.1] { clear(t, in: cb) }
    }

    func step(dt: Float, in cb: MTLCommandBuffer) {
        // 1. advect velocity through itself, then dye through velocity
        advect(src: vel.0, vel: vel.0, dst: vel.1, dt: dt, dissipation: velDissipation, in: cb)
        flip(&vel)
        advect(src: dye.0, vel: vel.0, dst: dye.1, dt: dt, dissipation: dyeDissipation, in: cb)
        flip(&dye)

        // 2. inject queued splats (dye into dye grid, momentum into velocity grid)
        for s in pending {
            if s.dye != 0 {
                splat(from: dye.0, to: dye.1, point: s.point, radius: s.radius,
                      value: SIMD4(s.dye, 0, 0, 0), in: cb)
                flip(&dye)
            }
            if s.momentum != .zero {
                splat(from: vel.0, to: vel.1, point: s.point, radius: s.radius,
                      value: SIMD4(s.momentum.x, s.momentum.y, 0, 0), in: cb)
                flip(&vel)
            }
        }

        // 3. project velocity to divergence-free (incompressibility). Before the
        // solve, bias the divergence input with each pending splat's volume
        // source so real +S divergence survives as a self-consistent outflow.
        dispatch(pDivergence, [vel.0, div.0], in: cb)
        for s in pending where s.displacement != 0 {
            divergenceSource(from: div.0, to: div.1, point: s.point,
                             radius: s.radius, amount: s.displacement, in: cb)
            flip(&div)
        }
        pending.removeAll()

        clear(prs.0, in: cb)
        for _ in 0..<jacobiIterations {
            dispatch(pJacobi, [prs.0, div.0, prs.1], in: cb)
            flip(&prs)
        }
        dispatch(pSubtract, [prs.0, vel.0, vel.1], in: cb)
        flip(&vel)

        // 4. Rayleigh friction + wall no-slip: bleed off momentum (foam/bottom
        // drag) and pin velocity to zero at the cup rim so nudges don't slosh
        // wall to wall. Final velocity op of the step. This also erodes the
        // source-driven outflow — fine and physical: foam fronts stall quickly.
        damp(from: vel.0, to: vel.1, damping: velocityDamping, in: cb)
        flip(&vel)

        dyeTexture = dye.0
    }

    // MARK: - kernel plumbing

    /// Ping-pong swap. `swap(&pair.0, &pair.1)` on a class property is two
    /// overlapping inout accesses to the same property — a runtime exclusivity
    /// crash. One inout of the whole pair is legal.
    private func flip(_ pair: inout (MTLTexture, MTLTexture)) {
        pair = (pair.1, pair.0)
    }

    private func encoder(_ cb: MTLCommandBuffer, _ p: MTLComputePipelineState,
                         _ textures: [MTLTexture]) -> MTLComputeCommandEncoder? {
        guard let e = cb.makeComputeCommandEncoder() else { return nil }
        e.setComputePipelineState(p)
        for (i, t) in textures.enumerated() { e.setTexture(t, index: i) }
        return e
    }

    private func run(_ e: MTLComputeCommandEncoder) {
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let n = MTLSize(width: (size + 15) / 16, height: (size + 15) / 16, depth: 1)
        e.dispatchThreadgroups(n, threadsPerThreadgroup: tg)
        e.endEncoding()
    }

    private func dispatch(_ p: MTLComputePipelineState, _ textures: [MTLTexture],
                          in cb: MTLCommandBuffer) {
        guard let e = encoder(cb, p, textures) else { return }
        run(e)
    }

    private func clear(_ t: MTLTexture, in cb: MTLCommandBuffer) {
        dispatch(pClear, [t], in: cb)
    }

    private func advect(src: MTLTexture, vel: MTLTexture, dst: MTLTexture,
                        dt: Float, dissipation: Float, in cb: MTLCommandBuffer) {
        guard let e = encoder(cb, pAdvect, [src, vel, dst]) else { return }
        var dt = dt, dis = dissipation
        e.setBytes(&dt, length: MemoryLayout<Float>.size, index: 0)
        e.setBytes(&dis, length: MemoryLayout<Float>.size, index: 1)
        run(e)
    }

    private func splat(from src: MTLTexture, to dst: MTLTexture, point: SIMD2<Float>,
                       radius: Float, value: SIMD4<Float>, in cb: MTLCommandBuffer) {
        guard let e = encoder(cb, pSplat, [src, dst]) else { return }
        var pt = point, r = radius, v = value
        e.setBytes(&pt, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        e.setBytes(&r, length: MemoryLayout<Float>.size, index: 1)
        e.setBytes(&v, length: MemoryLayout<SIMD4<Float>>.size, index: 2)
        run(e)
    }

    private func divergenceSource(from src: MTLTexture, to dst: MTLTexture,
                                  point: SIMD2<Float>, radius: Float, amount: Float,
                                  in cb: MTLCommandBuffer) {
        guard let e = encoder(cb, pDivSource, [src, dst]) else { return }
        var pt = point, r = radius, a = amount
        e.setBytes(&pt, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        e.setBytes(&r, length: MemoryLayout<Float>.size, index: 1)
        e.setBytes(&a, length: MemoryLayout<Float>.size, index: 2)
        run(e)
    }

    private func damp(from src: MTLTexture, to dst: MTLTexture,
                      damping: Float, in cb: MTLCommandBuffer) {
        guard let e = encoder(cb, pDamp, [src, dst]) else { return }
        var d = damping
        e.setBytes(&d, length: MemoryLayout<Float>.size, index: 0)
        run(e)
    }
}
