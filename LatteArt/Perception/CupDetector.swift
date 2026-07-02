import Vision
import CoreVideo
import simd
import CoreGraphics

/// Finds the cup rim in a camera frame and returns it as a `CupPose` ellipse
/// (spec §4.3). First pass: contour detection, then pick the largest roughly
/// circular closed contour and use its bounding box. Smoothed over time.
final class CupDetector {
    /// Latest smoothed pose, or nil until confidently detected.
    private(set) var pose: CupPose?

    private let smoothing: Float = 0.2   // EMA factor for stability

    /// Detect on a pixel buffer. Returns a pose (in top-left, y-down normalized
    /// view coordinates) or nil. Call at a throttled rate (a few Hz is plenty).
    @discardableResult
    func detect(in pixelBuffer: CVPixelBuffer) -> CupPose? {
        let request = VNDetectContoursRequest()
        request.contrastAdjustment = 1.6
        request.detectsDarkOnLight = true
        request.maximumImageDimension = 512

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first else { return nil }

        // Find the largest near-circular closed contour.
        var best: (box: CGRect, score: CGFloat)?
        for i in 0..<observation.contourCount {
            guard let contour = try? observation.contour(at: i) else { continue }
            let box = boundingBox(of: contour)
            let area = box.width * box.height
            guard area > 0.05 else { continue }                 // ignore tiny specks
            let aspect = box.width / max(box.height, 1e-4)
            guard aspect > 0.6, aspect < 1.7 else { continue }   // roughly round
            let score = area * (1 - abs(1 - aspect))
            if best == nil || score > best!.score { best = (box, score) }
        }

        guard let box = best?.box else { return nil }

        // Vision is bottom-left, y-up, normalized. Convert to top-left, y-down.
        let center = SIMD2<Float>(Float(box.midX), Float(1 - box.midY))
        let axes = SIMD2<Float>(Float(box.width) * 0.5, Float(box.height) * 0.5)
        let detected = CupPose(center: center, axes: axes, angle: 0, confidence: 1)

        pose = smoothed(previous: pose, next: detected)
        return pose
    }

    func reset() { pose = nil }

    private func smoothed(previous: CupPose?, next: CupPose) -> CupPose {
        guard let p = previous else { return next }
        func lerp(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> SIMD2<Float> {
            a * (1 - smoothing) + b * smoothing
        }
        return CupPose(center: lerp(p.center, next.center),
                       axes: lerp(p.axes, next.axes),
                       angle: p.angle * (1 - smoothing) + next.angle * smoothing,
                       confidence: 1)
    }

    private func boundingBox(of contour: VNContour) -> CGRect {
        let points = contour.normalizedPoints
        guard !points.isEmpty else { return .zero }
        var minX: Float = 1, minY: Float = 1, maxX: Float = 0, maxY: Float = 0
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: CGFloat(minX), y: CGFloat(minY),
                      width: CGFloat(maxX - minX), height: CGFloat(maxY - minY))
    }
}
