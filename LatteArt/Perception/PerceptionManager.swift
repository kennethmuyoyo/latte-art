import Metal
import CoreVideo
import Foundation
import simd

/// Ties the camera to perception: each frame becomes video + depth textures (for
/// the AR compositor and occlusion) and is run through the water-pour tracker,
/// whose results feed the simulation. Spec Perception module (§3, §6, §13).
final class PerceptionManager {
    let camera: CameraFeed
    let cupDetector = CupDetector()
    let waterTracker = WaterPourTracker()

    private weak var controller: SimulationController?
    private let lock = NSLock()
    private var _cameraTexture: MTLTexture?
    private var _depthTexture: MTLTexture?
    private var _depthBuffer: CVPixelBuffer?
    private var frameCount = 0

    /// Live depth of the cup surface in meters. Tracked every frame so the coffee
    /// follows the real surface (which rises as water is poured, or shifts if the
    /// cup moves). nil until first sampled after acquisition.
    private(set) var cupDepth: Float?
    /// How much closer than the surface (meters) something must be to occlude.
    var occlusionMargin: Float = 0.03
    /// EMA factor for surface tracking (higher = follows faster, noisier).
    var surfaceTrackingRate: Float = 0.15
    /// Reject a surface reading this much *closer* than current as foreground
    /// (a jug/hand over the cup) rather than a real surface move.
    var foregroundRejectMeters: Float = 0.06

    /// View aspect (width/height), set by the renderer so the cup pose can be
    /// mapped into the depth map's aspect-filled UV space.
    var viewAspect: Float = 9.0 / 19.5

    var cupDetectEveryNFrames = 10
    /// Auto cup detection stays OFF (contour detector false-positives); tap places.
    var autoDetectEnabled = false

    var hasDepth: Bool { camera.hasDepth }

    init(ctx: MetalContext) {
        camera = CameraFeed(device: ctx.device)
    }

    func attach(controller: SimulationController) {
        self.controller = controller
        waterTracker.onSample = { [weak controller] sample in controller?.ingestPour(sample) }
        camera.onFrame = { [weak self] video, depth, videoBuf, depthBuf in
            self?.handle(video: video, depth: depth, videoBuffer: videoBuf, depthBuffer: depthBuf)
        }
    }

    func start() { waterTracker.start(); camera.start() }
    func stop() { camera.stop(); waterTracker.stop() }

    func currentCameraTexture() -> MTLTexture? { lock.lock(); defer { lock.unlock() }; return _cameraTexture }
    func currentDepthTexture() -> MTLTexture? { lock.lock(); defer { lock.unlock() }; return _depthTexture }

    func releaseCupDepth() { cupDepth = nil }

    // MARK: - Frame handling (camera queue)

    private func handle(video: MTLTexture, depth: MTLTexture?,
                        videoBuffer: CVPixelBuffer, depthBuffer: CVPixelBuffer?) {
        lock.lock()
        _cameraTexture = video
        _depthTexture = depth
        _depthBuffer = depthBuffer
        lock.unlock()

        let acquired = controller?.isCupAcquired ?? false
        frameCount &+= 1

        if autoDetectEnabled, !acquired, frameCount % cupDetectEveryNFrames == 0 {
            if let pose = cupDetector.detect(in: videoBuffer) {
                DispatchQueue.main.async { [weak controller] in controller?.cupPose = pose }
            }
        }

        let pose = acquired ? (controller?.cupPose ?? .centeredDefault) : .centeredDefault
        waterTracker.process(pixelBuffer: videoBuffer, pose: pose)

        // Track the live cup-surface depth so the coffee follows the real surface.
        if acquired, let depthBuffer {
            trackSurfaceDepth(pose: pose, depthBuffer: depthBuffer)
        }
    }

    /// Sample depth across the cup interior and EMA-update the surface plane. Uses
    /// the median (robust to a jug covering part of the cup); rejects readings that
    /// jump much closer (a jug/hand over the surface) so the plane stays put.
    private func trackSurfaceDepth(pose: CupPose, depthBuffer buf: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return }

        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf)
        let rowBytes = CVPixelBufferGetBytesPerRow(buf)
        let scale = aspectFillScale(texW: w, texH: h)

        // Sample the cup center + a ring, in cup-UV, mapped to the depth map.
        var offsets: [SIMD2<Float>] = [SIMD2(0, 0)]
        for k in 0..<8 {
            let a = Float(k) / 8 * 2 * .pi
            offsets.append(SIMD2(cos(a), sin(a)) * 0.6)   // 60% of cup radius
        }

        var samples: [Float] = []
        for off in offsets {
            let cupUV = CupSpace.center + off * CupSpace.radius
            let viewPt = pose.viewPoint(fromCupUV: cupUV)
            let dUV = (viewPt - 0.5) * scale + 0.5
            let px = Int(dUV.x * Float(w)), py = Int(dUV.y * Float(h))
            guard px >= 0, px < w, py >= 0, py < h else { continue }
            let d = base.advanced(by: py * rowBytes).assumingMemoryBound(to: Float32.self)[px]
            if d.isFinite, d > 0.05, d < 10 { samples.append(d) }
        }
        guard !samples.isEmpty else { return }
        samples.sort()
        let median = samples[samples.count / 2]

        if let cur = cupDepth {
            // A reading much closer than current = foreground over the cup; hold.
            if median < cur - foregroundRejectMeters { return }
            cupDepth = cur * (1 - surfaceTrackingRate) + median * surfaceTrackingRate
        } else {
            cupDepth = median   // first lock
        }
    }

    /// Aspect-fill scale mapping the depth map onto the view (aspect only).
    private func aspectFillScale(texW: Int, texH: Int) -> SIMD2<Float> {
        let texAspect = Float(texW) / Float(max(texH, 1))
        return texAspect > viewAspect
            ? SIMD2<Float>(viewAspect / texAspect, 1)
            : SIMD2<Float>(1, texAspect / viewAspect)
    }
}
