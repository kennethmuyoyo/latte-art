import AVFoundation
import CoreVideo
import Metal

/// Live camera capture with synchronized **LiDAR depth**. Each frame yields a
/// video texture (for the AR background + Vision) and a depth texture + buffer
/// (for foreground occlusion — spec §13). Falls back to video-only when no depth
/// camera exists (non-Pro devices, Simulator).
final class CameraFeed: NSObject, AVCaptureDataOutputSynchronizerDelegate {
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private var synchronizer: AVCaptureDataOutputSynchronizer?
    private let queue = DispatchQueue(label: "com.signvrse.latteart.camera")
    private var textureCache: CVMetalTextureCache?
    private let device: MTLDevice

    // Keep the current frame's CVMetalTextures alive while their MTLTextures are used.
    private var retainedVideo: CVMetalTexture?
    private var retainedDepth: CVMetalTexture?

    /// `(video, depth?, videoBuffer, depthBuffer?)` on the camera queue each frame.
    var onFrame: ((MTLTexture, MTLTexture?, CVPixelBuffer, CVPixelBuffer?) -> Void)?

    private(set) var isConfigured = false
    private(set) var hasDepth = false

    init(device: MTLDevice) {
        self.device = device
        super.init()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self, granted else { return }
            self.queue.async {
                if !self.isConfigured { self.configure() }
                if self.isConfigured, !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    func stop() {
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .inputPriority

        // Prefer the rear LiDAR depth camera; fall back to plain wide-angle.
        let lidar = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back)
        let camera = lidar ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        guard let camera, let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else {
            session.commitConfiguration(); return
        }
        session.addInput(input)

        // Video.
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(videoOutput) else { session.commitConfiguration(); return }
        session.addOutput(videoOutput)
        setRotation(videoOutput.connection(with: .video))

        // Depth (LiDAR).
        if lidar != nil, session.canAddOutput(depthOutput) {
            session.addOutput(depthOutput)
            depthOutput.isFilteringEnabled = true      // fill small holes
            setRotation(depthOutput.connection(with: .depthData))
            depthOutput.connection(with: .depthData)?.isEnabled = true
            selectDepthFormat(on: camera)
            hasDepth = true
        }

        session.commitConfiguration()

        if hasDepth {
            let sync = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthOutput])
            sync.setDelegate(self, queue: queue)
            synchronizer = sync
        } else {
            // Video-only path.
            videoOutput.setSampleBufferDelegate(VideoOnlyProxy(feed: self), queue: queue)
        }
        isConfigured = true
    }

    private func setRotation(_ connection: AVCaptureConnection?) {
        guard let connection else { return }
        if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
    }

    private func selectDepthFormat(on camera: AVCaptureDevice) {
        guard let fmt = camera.activeFormat.supportedDepthDataFormats.first(where: {
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat16
        }) else { return }
        try? camera.lockForConfiguration()
        camera.activeDepthDataFormat = fmt
        camera.unlockForConfiguration()
    }

    // MARK: - Synchronized (video + depth)

    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput collection: AVCaptureSynchronizedDataCollection) {
        guard let cache = textureCache,
              let videoData = collection.synchronizedData(for: videoOutput) as? AVCaptureSynchronizedSampleBufferData,
              !videoData.sampleBufferWasDropped,
              let videoPB = CMSampleBufferGetImageBuffer(videoData.sampleBuffer) else { return }

        guard let videoTex = makeTexture(from: videoPB, format: .bgra8Unorm, cache: cache, retain: { self.retainedVideo = $0 }) else { return }

        var depthTex: MTLTexture?
        var depthPB: CVPixelBuffer?
        if let depthData = collection.synchronizedData(for: depthOutput) as? AVCaptureSynchronizedDepthData,
           !depthData.depthDataWasDropped {
            let converted = depthData.depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
            let map = converted.depthDataMap
            depthPB = map
            depthTex = makeTexture(from: map, format: .r32Float, cache: cache, retain: { self.retainedDepth = $0 })
        }

        onFrame?(videoTex, depthTex, videoPB, depthPB)
    }

    private func makeTexture(from pb: CVPixelBuffer, format: MTLPixelFormat,
                             cache: CVMetalTextureCache,
                             retain: (CVMetalTexture) -> Void) -> MTLTexture? {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        var cv: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pb, nil, format, w, h, 0, &cv)
        guard status == kCVReturnSuccess, let cv, let tex = CVMetalTextureGetTexture(cv) else { return nil }
        retain(cv)
        return tex
    }

    // Bridges the video-only (no-depth) delegate back into `onFrame`.
    private final class VideoOnlyProxy: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        weak var feed: CameraFeed?
        init(feed: CameraFeed) { self.feed = feed }
        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                           from connection: AVCaptureConnection) {
            guard let feed, let cache = feed.textureCache,
                  let pb = CMSampleBufferGetImageBuffer(sampleBuffer),
                  let tex = feed.makeTexture(from: pb, format: .bgra8Unorm, cache: cache,
                                             retain: { feed.retainedVideo = $0 }) else { return }
            feed.onFrame?(tex, nil, pb, nil)
        }
    }
}
