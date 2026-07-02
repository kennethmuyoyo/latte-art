import Metal
import simd

/// Parameter block shared with `Fluid.metal`. Field order and sizes MUST match
/// the Metal `FluidParams` struct exactly (float2 is 8-byte aligned; 32 bytes).
struct FluidParams {
    var cupCenter: SIMD2<Float> = CupSpace.center
    var cupRadius: Float = CupSpace.radius
    var dt: Float = 1.0 / 60.0
    var velDissipation: Float = 0.998
    var dyeDissipation: Float = 0.997
    var heightDissipation: Float = 0.94
    var wallDrag: Float = 0.35
}

/// The contained top-down fluid solver (spec Focus A) plus the light surface
/// height field (spec Focus B). Owns all GPU textures and pipelines and drives
/// one Stable-Fluids step per frame. Pour input enters only through `splat*`.
final class FluidSimulation {
    static let gridSize = 256

    let ctx: MetalContext
    var params = FluidParams()

    /// Milk/velocity injection radius in UV (pour "footprint").
    var pourRadius: Float = 0.045
    /// How many Jacobi iterations per step (higher = stiffer/incompressible).
    var jacobiIterations = 28

    // Ping-pong texture pairs.
    private var velocity: [MTLTexture]
    private var dye: [MTLTexture]
    private var pressure: [MTLTexture]
    private var height: [MTLTexture]
    private let divergenceTex: MTLTexture
    /// Final RGBA output the compositor samples (crema/milk with alpha mask).
    let outputTexture: MTLTexture

    private var vi = 0, di = 0, pi = 0, hi = 0

    // Pipelines.
    private let pAdvect, pDivergence, pJacobi, pSubtract, pRelaxHeight, pSplat, pRender, pClear: MTLComputePipelineState

    private let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
    private var threadgroups: MTLSize {
        let n = FluidSimulation.gridSize
        return MTLSize(width: (n + 15) / 16, height: (n + 15) / 16, depth: 1)
    }

    init(ctx: MetalContext) {
        self.ctx = ctx
        let n = FluidSimulation.gridSize
        func pair(_ fmt: MTLPixelFormat) -> [MTLTexture] {
            [ctx.makeTexture(width: n, height: n, pixelFormat: fmt),
             ctx.makeTexture(width: n, height: n, pixelFormat: fmt)]
        }
        velocity = pair(.rg16Float)
        dye = pair(.r16Float)
        pressure = pair(.r16Float)
        height = pair(.r16Float)
        divergenceTex = ctx.makeTexture(width: n, height: n, pixelFormat: .r16Float)
        outputTexture = ctx.makeTexture(width: n, height: n, pixelFormat: .rgba16Float,
                                        usage: [.shaderRead, .shaderWrite])

        pAdvect = ctx.computePipeline("advect")
        pDivergence = ctx.computePipeline("divergence")
        pJacobi = ctx.computePipeline("jacobi")
        pSubtract = ctx.computePipeline("subtractGradient")
        pRelaxHeight = ctx.computePipeline("relaxHeight")
        pSplat = ctx.computePipeline("splat")
        pRender = ctx.computePipeline("renderCrema")
        pClear = ctx.computePipeline("clearTex")

        reset()
    }

    // MARK: - Public control

    /// Wipe all fields to an empty cup.
    func reset() {
        guard let cb = ctx.queue.makeCommandBuffer() else { return }
        for t in velocity + dye + pressure + height + [divergenceTex] {
            clear(t, in: cb)
        }
        cb.commit()
        vi = 0; di = 0; pi = 0; hi = 0
    }

    /// Inject a velocity impulse (force) at a UV point.
    func splatVelocity(atUV uv: SIMD2<Float>, force: SIMD2<Float>) {
        guard let cb = ctx.queue.makeCommandBuffer() else { return }
        splat(src: velocity[vi], dst: velocity[1 - vi], at: uv,
              value: SIMD3<Float>(force.x, force.y, 0), in: cb)
        vi = 1 - vi
        cb.commit()
    }

    /// Inject milk dye (concentration) at a UV point.
    func splatDye(atUV uv: SIMD2<Float>, amount: Float) {
        guard let cb = ctx.queue.makeCommandBuffer() else { return }
        splat(src: dye[di], dst: dye[1 - di], at: uv, value: SIMD3<Float>(amount, 0, 0), in: cb)
        di = 1 - di
        cb.commit()
    }

    /// Add a surface dimple at a UV point (drives shading only).
    func splatHeight(atUV uv: SIMD2<Float>, amount: Float) {
        guard let cb = ctx.queue.makeCommandBuffer() else { return }
        splat(src: height[hi], dst: height[1 - hi], at: uv, value: SIMD3<Float>(amount, 0, 0), in: cb)
        hi = 1 - hi
        cb.commit()
    }

    /// Convenience: translate one pour sample into the right injections.
    /// During filling we mostly push flow + surface; during foam we also lay milk.
    func apply(pour: PourSample, layingMilk: Bool) {
        let f = max(pour.flowRate, 0.0001)
        // Velocity from the pour's own motion, scaled up so it stirs the cup.
        var force = pour.velocity * (40.0 * f)
        if simd_length(force) < 1e-4 { force = SIMD2<Float>(0, 4 * f) } // gentle default stir
        splatVelocity(atUV: pour.uv, force: force)
        splatHeight(atUV: pour.uv, amount: 0.9 * f)
        if layingMilk { splatDye(atUV: pour.uv, amount: 0.85 * f) }
    }

    /// Advance the simulation one step and re-render the output texture.
    func step(dt: Float, fillLevel: Float) {
        params.dt = dt
        guard let cb = ctx.queue.makeCommandBuffer() else { return }

        // 1. Advect velocity by itself.
        advect(vel: velocity[vi], src: velocity[vi], dst: velocity[1 - vi],
               dissipation: params.velDissipation, in: cb)
        vi = 1 - vi
        let advectingVel = velocity[vi]   // updated velocity carries the scalars

        // 2. Advect dye and height along the (now advected) velocity field.
        advect(vel: advectingVel, src: dye[di], dst: dye[1 - di],
               dissipation: params.dyeDissipation, in: cb)
        di = 1 - di
        advect(vel: advectingVel, src: height[hi], dst: height[1 - hi],
               dissipation: 1.0, in: cb)      // height relaxes separately
        hi = 1 - hi
        relaxHeight(src: height[hi], dst: height[1 - hi], in: cb)
        hi = 1 - hi

        // 3. Project velocity to divergence-free (incompressible) within the cup.
        divergence(vel: velocity[vi], dst: divergenceTex, in: cb)
        clear(pressure[pi], in: cb)
        for _ in 0..<jacobiIterations {
            jacobi(pIn: pressure[pi], dst: pressure[1 - pi], in: cb)
            pi = 1 - pi
        }
        subtractGradient(p: pressure[pi], velIn: velocity[vi], dst: velocity[1 - vi], in: cb)
        vi = 1 - vi

        // 4. Render crema/milk with fill-level fade + height shading.
        render(fillLevel: fillLevel, in: cb)

        cb.commit()
    }

    // MARK: - Pass helpers

    private func setParams(_ enc: MTLComputeCommandEncoder, index: Int) {
        var p = params
        enc.setBytes(&p, length: MemoryLayout<FluidParams>.stride, index: index)
    }

    private func dispatch(_ pipe: MTLComputePipelineState, _ cb: MTLCommandBuffer,
                          _ configure: (MTLComputeCommandEncoder) -> Void) {
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(pipe)
        configure(enc)
        enc.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        enc.endEncoding()
    }

    private func clear(_ tex: MTLTexture, in cb: MTLCommandBuffer) {
        dispatch(pClear, cb) { $0.setTexture(tex, index: 0) }
    }

    private func advect(vel: MTLTexture, src: MTLTexture, dst: MTLTexture,
                        dissipation: Float, in cb: MTLCommandBuffer) {
        dispatch(pAdvect, cb) { enc in
            enc.setTexture(vel, index: 0)   // advecting velocity field
            enc.setTexture(src, index: 1)
            enc.setTexture(dst, index: 2)
            self.setParams(enc, index: 0)
            var d = dissipation
            enc.setBytes(&d, length: MemoryLayout<Float>.stride, index: 1)
        }
    }

    private func relaxHeight(src: MTLTexture, dst: MTLTexture, in cb: MTLCommandBuffer) {
        dispatch(pRelaxHeight, cb) { enc in
            enc.setTexture(src, index: 0)
            enc.setTexture(dst, index: 1)
            self.setParams(enc, index: 0)
        }
    }

    private func divergence(vel: MTLTexture, dst: MTLTexture, in cb: MTLCommandBuffer) {
        dispatch(pDivergence, cb) { enc in
            enc.setTexture(vel, index: 0)
            enc.setTexture(dst, index: 1)
            self.setParams(enc, index: 0)
        }
    }

    private func jacobi(pIn: MTLTexture, dst: MTLTexture, in cb: MTLCommandBuffer) {
        dispatch(pJacobi, cb) { enc in
            enc.setTexture(pIn, index: 0)
            enc.setTexture(self.divergenceTex, index: 1)
            enc.setTexture(dst, index: 2)
            self.setParams(enc, index: 0)
        }
    }

    private func subtractGradient(p: MTLTexture, velIn: MTLTexture, dst: MTLTexture,
                                  in cb: MTLCommandBuffer) {
        dispatch(pSubtract, cb) { enc in
            enc.setTexture(p, index: 0)
            enc.setTexture(velIn, index: 1)
            enc.setTexture(dst, index: 2)
            self.setParams(enc, index: 0)
        }
    }

    private func splat(src: MTLTexture, dst: MTLTexture,
                       at uv: SIMD2<Float>, value: SIMD3<Float>, in cb: MTLCommandBuffer) {
        dispatch(pSplat, cb) { enc in
            enc.setTexture(src, index: 0)
            enc.setTexture(dst, index: 1)
            self.setParams(enc, index: 0)
            var c = uv; enc.setBytes(&c, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            var v = value; enc.setBytes(&v, length: MemoryLayout<SIMD3<Float>>.stride, index: 2)
            var r = self.pourRadius; enc.setBytes(&r, length: MemoryLayout<Float>.stride, index: 3)
        }
    }

    private func render(fillLevel: Float, in cb: MTLCommandBuffer) {
        dispatch(pRender, cb) { enc in
            enc.setTexture(self.dye[self.di], index: 0)
            enc.setTexture(self.height[self.hi], index: 1)
            enc.setTexture(self.outputTexture, index: 2)
            self.setParams(enc, index: 0)
            var f = fillLevel
            enc.setBytes(&f, length: MemoryLayout<Float>.stride, index: 1)
        }
    }
}
