import Metal
import MetalKit

/// Shared Metal device, command queue, and shader library. One per app.
final class MetalContext {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary

    /// Fails only on devices/simulators without Metal (should not happen on
    /// supported targets). Callers can fall back to a non-Metal placeholder.
    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else {
            return nil
        }
        self.device = device
        self.queue = queue
        self.library = library
    }

    func computePipeline(_ function: String) -> MTLComputePipelineState {
        guard let fn = library.makeFunction(name: function),
              let pipe = try? device.makeComputePipelineState(function: fn) else {
            fatalError("Missing or invalid Metal function: \(function)")
        }
        return pipe
    }

    func makeTexture(width: Int, height: Int,
                     pixelFormat: MTLPixelFormat,
                     usage: MTLTextureUsage = [.shaderRead, .shaderWrite]) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        desc.usage = usage
        desc.storageMode = .private
        guard let tex = device.makeTexture(descriptor: desc) else {
            fatalError("Failed to allocate \(width)x\(height) texture")
        }
        return tex
    }
}
