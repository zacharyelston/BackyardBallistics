import ARKit
import CoreImage
import CoreLocation
import RealityKit
import RangingKit

/// Owns the AR session for one ranging: keeps the world frame steady across photos,
/// tracks how far the phone has moved from the first photo, and knows where the lie is by GPS.
final class RangingSession: NSObject, ObservableObject, ARSessionDelegate, CLLocationManagerDelegate {
    @Published var sightings: [PoleSighting] = []
    @Published private(set) var baseline: Double = 0
    @Published private(set) var tracking = "Starting camera…"
    @Published private(set) var trackingReady = false
    @Published private(set) var lieLocation: GeoPoint?
    @Published private(set) var currentLocation: CLLocation?

    weak var view: ARView?
    private let location = CLLocationManager()
    private let ciContext = CIContext()
    private var frameCount = 0

    func attach(_ view: ARView) {
        self.view = view
        let config = ARWorldTrackingConfiguration()
        // +X east, -Z north, +Y up: lets the ranged offset turn into a GPS point for the flag gate.
        config.worldAlignment = .gravityAndHeading
        if let fourK = ARWorldTrackingConfiguration.recommendedVideoFormatFor4KResolution {
            config.videoFormat = fourK
        }
        view.session.delegate = self
        view.session.run(config)
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.requestWhenInUseAuthorization()
        location.startUpdatingLocation()
    }

    func pause() {
        view?.session.pause()
        location.stopUpdatingLocation()
    }

    func reset() {
        sightings = []
        lieLocation = nil
        baseline = 0
    }

    /// Freezes the current camera frame with its pose and intrinsics for marking.
    func capture() -> FrozenFrame? {
        guard let frame = view?.session.currentFrame else { return nil }
        let camera = frame.camera
        guard case .normal = camera.trackingState else { return nil }
        let buffer = frame.capturedImage
        let upright = CIImage(cvPixelBuffer: buffer).oriented(.right)
        guard let cg = ciContext.createCGImage(upright, from: upright.extent) else { return nil }
        let k = Intrinsics(matrix: camera.intrinsics, width: Int(camera.imageResolution.width),
                           height: Int(camera.imageResolution.height))
        let t = camera.transform
        let pose = CameraPose(simd_double4x4(columns: (SIMD4<Double>(t.columns.0), SIMD4<Double>(t.columns.1),
                                                       SIMD4<Double>(t.columns.2), SIMD4<Double>(t.columns.3))))
        return FrozenFrame(image: cg, intrinsics: k, lens: "1× (AR)", approximateIntrinsics: false, pose: pose)
    }

    func add(_ sighting: PoleSighting) {
        if sightings.isEmpty, let c = currentLocation {
            lieLocation = GeoPoint(latitude: c.coordinate.latitude, longitude: c.coordinate.longitude)
        }
        sightings.append(sighting)
    }

    // MARK: ARSessionDelegate (main queue)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameCount += 1
        guard frameCount % 6 == 0 else { return }
        let p = frame.camera.transform.columns.3
        if let first = sightings.first?.pose.position {
            baseline = max(baseline, ((Double(p.x) - first.x) * (Double(p.x) - first.x) +
                                      (Double(p.z) - first.z) * (Double(p.z) - first.z)).squareRoot())
        }
        switch frame.camera.trackingState {
        case .normal:
            tracking = "Tracking"; trackingReady = true
        case .notAvailable:
            tracking = "Tracking unavailable"; trackingReady = false
        case .limited(let reason):
            trackingReady = false
            switch reason {
            case .initializing: tracking = "Move the phone slowly to start tracking"
            case .excessiveMotion: tracking = "Slow down"
            case .insufficientFeatures: tracking = "Point at more detail (grass, fence, ground)"
            case .relocalizing: tracking = "Relocalizing…"
            @unknown default: tracking = "Tracking limited"
            }
        }
    }

    // MARK: CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        currentLocation = locations.last
    }
}
