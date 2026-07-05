import Foundation

/// Abstract source of pour input. Touch (`TouchPourSource`) and the scripted
/// demo (`AutoPourSource`) conform, so the rest of the app is agnostic to how the
/// pour is sensed. Real pour detection (ripples on the tracked surface) will be a
/// future `PourSource`, so swapping it in touches no simulation code.
protocol PourSource: AnyObject {
    /// The most recent sample, or `nil` when nothing is being poured right now.
    var current: PourSample? { get }

    /// Called every frame the source is active. `onSample` fires with the newest
    /// pour observation, or is simply not called on frames with no pour.
    var onSample: ((PourSample) -> Void)? { get set }

    func start()
    func stop()
}
