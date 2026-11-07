import Foundation
import CoreGeo

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
}
