import Metal

/// Shared Metal device + command queue + default shader library for the
/// Simulation layer. Small on purpose — everything downstream (fluid solver,
/// blitter) borrows these three handles rather than each creating its own.
final class MetalContext {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { return nil }
        self.device = device
        self.queue = queue
        self.library = library
    }
}
