import ARKit
import simd
import SwiftAprilTag

/// Fixed tag-ID scheme + physical tag sizes. IDs must match the tags actually
/// printed and mounted on the cup/pitcher; sizes must match their printed
/// outer-black-border edge length (meters), NOT the printed square including
/// the white margin.
enum AprilTagRoles {
    static let cupTagIDs: [Int] = [0, 1, 2]
    static let pitcherSpoutID = 10
    static let pitcherBackID = 11

    static var cupTagSizeMeters: Double = 0.024
    static var pitcherTagSizeMeters: Double = 0.024
}

/// Runs AprilTag detection + pose estimation against each ARFrame and reports
/// every detected tag's world-space position, role-agnostic (callers filter by
/// `AprilTagRoles`). Detection runs off the main thread; frames are dropped
/// (not queued) while a detection is already in flight, since ARKit calls back
/// at up to 60Hz and detection can take longer than one frame.
final class AprilTagTracker {
    private let detector: Detector
    private let queue = DispatchQueue(label: "com.latteart.apriltag", qos: .userInitiated)
    private var busy = false

    /// SwiftAprilTag's `TagPose` comes straight out of the upstream AprilTag
    /// C library's `estimate_tag_pose`, which solves a pinhole camera model
    /// (`u = fx*X/Z + cx`, `v = fy*Y/Z + cy`): that convention is X-right,
    /// Y-DOWN, Z-FORWARD (into the scene) — standard computer-vision/OpenCV
    /// axes. ARKit's camera-local space is X-right, Y-UP, Z-BACKWARD (the
    /// camera looks down -Z). The two disagree on Y and Z, so every tag pose
    /// needs this fixed 180°-about-X flip before it's combined with
    /// `ARCamera.transform`. This mirrors the exact `(x, -y, -depth)` flip
    /// the project's prior LiDAR-unprojection code already applied for the
    /// same reason.
    private static let openCVToARKit = simd_float4x4(
        SIMD4<Float>(1, 0, 0, 0),
        SIMD4<Float>(0, -1, 0, 0),
        SIMD4<Float>(0, 0, -1, 0),
        SIMD4<Float>(0, 0, 0, 1)
    )

    init() throws {
        detector = try Detector(families: [.tag36h11])
    }

    /// Non-blocking. `completion` is called on the main thread with this
    /// frame's detections (or the previous call's frame skipped entirely, not
    /// queued, if a detection is already running).
    func process(frame: ARFrame, completion: @escaping ([Int: SIMD3<Float>]) -> Void) {
        guard !busy else { return }
        busy = true

        let pixelBuffer = frame.capturedImage
        let intr = frame.camera.intrinsics
        let camTransform = frame.camera.transform
        let intrinsics = CameraIntrinsics(fx: Double(intr.columns.0.x), fy: Double(intr.columns.1.y),
                                          cx: Double(intr.columns.2.x), cy: Double(intr.columns.2.y))

        queue.async { [detector] in
            var world: [Int: SIMD3<Float>] = [:]
            if let detections = try? detector.detect(pixelBuffer: pixelBuffer) {
                for d in detections {
                    let size = AprilTagRoles.cupTagIDs.contains(d.id)
                        ? AprilTagRoles.cupTagSizeMeters : AprilTagRoles.pitcherTagSizeMeters
                    guard let pose = d.estimatePose(intrinsics: intrinsics, tagSize: size) else { continue }
                    let worldTransform = camTransform * Self.openCVToARKit * pose.transform
                    let t = worldTransform.columns.3
                    world[d.id] = SIMD3<Float>(t.x, t.y, t.z)
                }
            }
            DispatchQueue.main.async {
                completion(world)
                self.busy = false
            }
        }
    }
}
