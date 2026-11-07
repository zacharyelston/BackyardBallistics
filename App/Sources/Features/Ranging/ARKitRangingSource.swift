import ARKit
import CoreImage
import CoreLocation
import RealityKit
import CoreGeo
import RangingKit

/// The real capture source: ARKit world tracking for camera poses, Core Location for the lie.
///
/// This is the only ranging file that touches ARKit; everything above it works through
/// `RangingCaptureSource`.
///
/// **Coordinate convention.** ARKit's camera looks down −Z with +Y up in the sensor's landscape
/// orientation; `CameraPose.ray(through:intrinsics:)` follows the same convention. The session runs
/// `.gravityAndHeading` (+X east, −Z north) so a ranged offset can become a GPS point for the flag
/// check; the compass makes that direction good to roughly ±10°.
final class ARKitRangingSource: NSObject, RangingCaptureSource, ARSessionDelegate, CLLocationManagerDelegate {
    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    let isSimulated = false
    var onStatus: ((CaptureStatus) -> Void)?
    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)

    private let location = CLLocationManager()
    private let ciContext = CIContext()
    private var frameCount = 0
    private var tracking: CaptureTracking = .starting
    private var position: SIMD3<Double>?
    private var lastLocation: CLLocation?

    func start() {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravityAndHeading
        if let fourK = ARWorldTrackingConfiguration.recommendedVideoFormatFor4KResolution {
            config.videoFormat = fourK
        }
        arView.session.delegate = self
        arView.session.run(config)
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.requestWhenInUseAuthorization()
        location.startUpdatingLocation()
    }

    func stop() {
        arView.session.pause()
        location.stopUpdatingLocation()
    }

    func capture() -> FrozenFrame? {
        guard let frame = arView.session.currentFrame else { return nil }
        let camera = frame.camera
        guard case .normal = camera.trackingState else { return nil }
        let upright = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
        guard let cg = ciContext.createCGImage(upright, from: upright.extent) else { return nil }
        let k = Intrinsics(matrix: camera.intrinsics, width: Int(camera.imageResolution.width),
                           height: Int(camera.imageResolution.height))
        let t = camera.transform
        let pose = CameraPose(simd_double4x4(columns: (SIMD4<Double>(t.columns.0), SIMD4<Double>(t.columns.1),
                                                       SIMD4<Double>(t.columns.2), SIMD4<Double>(t.columns.3))))
        return FrozenFrame(image: cg, intrinsics: k, lens: "Wide (AR)", approximateIntrinsics: false, pose: pose)
    }

    private func emit() {
        onStatus?(CaptureStatus(
            tracking: tracking,
            cameraPosition: position,
            location: lastLocation.map { GeoPoint(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) },
            horizontalAccuracy: lastLocation?.horizontalAccuracy))
    }

    // MARK: ARSessionDelegate (main queue)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameCount += 1
        guard frameCount % 6 == 0 else { return } // ten updates a second is plenty for the UI
        let p = frame.camera.transform.columns.3
        position = SIMD3(Double(p.x), Double(p.y), Double(p.z))
        switch frame.camera.trackingState {
        case .normal: tracking = .normal
        case .notAvailable: tracking = .unavailable
        case .limited(let reason):
            switch reason {
            case .initializing: tracking = .limited("Move the phone slowly to start tracking")
            case .excessiveMotion: tracking = .limited("Slow down")
            case .insufficientFeatures: tracking = .limited("Point at more detail (grass, fence, ground)")
            case .relocalizing: tracking = .limited("Relocalizing…")
            @unknown default: tracking = .limited("Tracking limited")
            }
        }
        emit()
    }

    // MARK: CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        lastLocation = locations.last
        emit()
    }
}
