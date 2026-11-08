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
        // Live video is 1920 × 1440 on every iPhone; what matters for ranging is the full-resolution
        // still taken at Freeze, so prefer the format that supports capturing one.
        if let hiRes = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            config.videoFormat = hiRes
        } else if let fourK = ARWorldTrackingConfiguration.recommendedVideoFormatFor4KResolution {
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
        guard let frame = arView.session.currentFrame, case .normal = frame.camera.trackingState else { return nil }
        return frozen(frame, lens: "Wide (AR)")
    }

    func captureStill(_ done: @escaping (FrozenFrame?) -> Void) {
        arView.session.captureHighResolutionFrame { [weak self] frame, _ in
            DispatchQueue.main.async {
                guard let self else { return done(nil) }
                if let frame, let still = self.frozen(frame, lens: "Wide (AR, full resolution)") {
                    done(still)
                } else {
                    done(self.capture()) // no high-resolution frame on this device or right now: use the live one
                }
            }
        }
    }

    /// An upright image of the frame, with the intrinsics and pose of that exact frame.
    private func frozen(_ frame: ARFrame, lens: String) -> FrozenFrame? {
        let camera = frame.camera
        let upright = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
        guard let cg = ciContext.createCGImage(upright, from: upright.extent) else { return nil }
        let k = Intrinsics(matrix: camera.intrinsics, width: Int(camera.imageResolution.width),
                           height: Int(camera.imageResolution.height))
        let t = camera.transform
        let pose = CameraPose(simd_double4x4(columns: (SIMD4<Double>(t.columns.0), SIMD4<Double>(t.columns.1),
                                                       SIMD4<Double>(t.columns.2), SIMD4<Double>(t.columns.3))))
        return FrozenFrame(image: cg, intrinsics: k, lens: lens, approximateIntrinsics: false, pose: pose)
    }

    func liveIntrinsics() -> Intrinsics? {
        guard let camera = arView.session.currentFrame?.camera else { return nil }
        return Intrinsics(matrix: camera.intrinsics, width: Int(camera.imageResolution.width),
                          height: Int(camera.imageResolution.height))
    }

    /// From the camera transform; the session's `.gravityAndHeading` alignment makes −Z true north.
    func liveAim() -> CaptureAim? {
        guard let camera = arView.session.currentFrame?.camera, case .normal = camera.trackingState else { return nil }
        let t = camera.transform
        let pose = CameraPose(simd_double4x4(columns: (SIMD4<Double>(t.columns.0), SIMD4<Double>(t.columns.1),
                                                       SIMD4<Double>(t.columns.2), SIMD4<Double>(t.columns.3))))
        let aim = pose.aim
        return CaptureAim(bearing: aim.bearing, angleBelowLevel: aim.angleBelowLevel)
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
