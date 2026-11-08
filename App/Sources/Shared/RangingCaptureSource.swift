import Foundation
import CoreGeo
import RangingKit

/// How well the capture source knows where the phone is.
enum CaptureTracking: Equatable {
    case starting
    case normal
    case limited(String)
    case unavailable

    var ready: Bool { self == .normal }

    var label: String {
        switch self {
        case .starting: return "Starting camera…"
        case .normal: return "Tracking"
        case .limited(let why): return why
        case .unavailable: return "Tracking unavailable"
        }
    }
}

/// One update from a capture source. Sources send these on the main queue.
struct CaptureStatus {
    var tracking: CaptureTracking
    /// Camera position in the session's world frame (metres; +X east, -Z north, +Y up).
    var cameraPosition: SIMD3<Double>?
    var location: GeoPoint?
    /// GPS horizontal accuracy, metres.
    var horizontalAccuracy: Double?
}

/// Where the crosshair (the optical axis) points, from the capture source's own tracking.
struct CaptureAim: Equatable {
    /// Compass bearing, degrees clockwise from true north.
    var bearing: Double
    /// Angle below level, degrees (+ looking down).
    var angleBelowLevel: Double
}

/// The seam that keeps ranging testable without a phone.
///
/// ARKit needs a real camera and motion tracking, so nothing above this protocol may touch ARKit.
/// `ARKitRangingSource` implements it on a device; `SimulatedRangingSource` renders a synthetic
/// pole from known poses so the whole flow (capture, mark, solve, flag check) runs in the
/// Simulator and in tests.
protocol RangingCaptureSource: AnyObject {
    var isSimulated: Bool { get }
    /// Called on the main queue whenever tracking, position or location changes.
    var onStatus: ((CaptureStatus) -> Void)? { get set }
    func start()
    func stop()
    /// Freezes the current frame, with its pose and intrinsics, for marking. Nil if tracking isn't ready.
    func capture() -> FrozenFrame?
    /// The sharpest still the camera can give right now, with its own intrinsics and pose: a
    /// full-resolution frame where the device offers one (every iPhone on iOS 16+ through ARKit),
    /// else the live frame. Calls back on the main queue; nil if there is no frame at all.
    func captureStill(_ done: @escaping (FrozenFrame?) -> Void)
    /// Intrinsics of the live feed's native (landscape) buffer, for the reticle. Nil until the first frame.
    func liveIntrinsics() -> Intrinsics?
    /// Where the optical axis points now. Nil until tracking has a heading.
    func liveAim() -> CaptureAim?
}
