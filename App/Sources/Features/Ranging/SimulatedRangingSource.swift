import UIKit
import simd
import CoreGeo
import RangingKit

/// A deterministic stand-in for the camera: a pole of known height at a known spot, photographed
/// by a phone held upright in portrait that steps sideways one metre per photo.
///
/// No randomness and no clock, so the same taps always give the same range. The frames carry real
/// poses and intrinsics in ARKit's conventions, so marking, the solver, the flag check and the log
/// all run exactly as they would on a phone.
final class SimulatedRangingSource: RangingCaptureSource {
    struct Scene {
        /// Pole base in the session's world frame: 3 m right, 0.3 m downhill, 40 m north.
        var poleBase = SIMD3<Double>(3, -0.3, -40)
        var poleHeight: Double
        var eyeHeight = 1.5
        var stepMetres = 1.0
        /// GPS position of the first photo (the sample course's first firing point).
        var origin = GeoPoint(latitude: 42.360120, longitude: -71.058880)
    }

    let isSimulated = true
    var onStatus: ((CaptureStatus) -> Void)?
    let scene: Scene
    /// A 1920 × 1440 landscape sensor, like ARKit's default wide format.
    let intrinsics = Intrinsics(fx: 1450, fy: 1450, cx: 960, cy: 720, width: 1920, height: 1440)
    private(set) var eye: SIMD3<Double>

    init(poleHeight: Double) {
        scene = Scene(poleHeight: poleHeight)
        eye = SIMD3(0, scene.eyeHeight, 0)
    }

    var pose: CameraPose { CameraPose.portrait(eye: eye, facing: scene.poleBase) }

    /// The flag point that matches this scene, so the flag check passes in the Simulator.
    var flagPoint: GeoPoint {
        let en = Geo.eastNorth(arOffset: scene.poleBase.x, scene.poleBase.z)
        return Geo.offset(scene.origin, east: en.east, north: en.north)
    }

    private var location: GeoPoint {
        let en = Geo.eastNorth(arOffset: eye.x, eye.z)
        return Geo.offset(scene.origin, east: en.east, north: en.north)
    }

    func start() {
        DispatchQueue.main.async { [weak self] in self?.emit() }
    }

    func stop() {}

    func capture() -> FrozenFrame? {
        guard let image = render(scale: 1) else { return nil }
        let frame = FrozenFrame(image: image, intrinsics: intrinsics, lens: "Simulated",
                                approximateIntrinsics: false, pose: pose)
        eye.x += scene.stepMetres // step sideways for the next photo
        emit()
        return frame
    }

    /// The live "camera" view, at a reduced size.
    func preview() -> CGImage? { render(scale: 0.3) }

    private func emit() {
        onStatus?(CaptureStatus(tracking: .normal, cameraPosition: eye, location: location, horizontalAccuracy: 4))
    }

    // MARK: Rendering

    /// Draws the upright (portrait) photo. Buffer pixels map to the display as the real camera's
    /// do: a frame rotated 90° clockwise, so buffer x runs down the screen.
    private func render(scale: CGFloat) -> CGImage? {
        let k = intrinsics, pose = self.pose
        let size = CGSize(width: CGFloat(k.height) * scale, height: CGFloat(k.width) * scale)
        func display(_ world: SIMD3<Double>) -> CGPoint? {
            guard let p = pose.project(world, intrinsics: k) else { return nil }
            return CGPoint(x: (CGFloat(k.height) - 1 - CGFloat(p.y)) * scale, y: CGFloat(p.x) * scale)
        }
        let toPole = scene.poleBase - eye
        let distance = simd_length(SIMD2(toPole.x, toPole.z))
        let forward = simd_normalize(SIMD3(toPole.x, 0, toPole.z))
        let horizonY = display(eye + forward * 5000)?.y ?? size.height / 2
        let pxPerMetre = CGFloat(k.fx / distance) * scale
        let H = scene.poleHeight
        let base = scene.poleBase

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let c = ctx.cgContext
            // Sky and grass
            UIColor(red: 0.62, green: 0.78, blue: 0.93, alpha: 1).setFill()
            c.fill(CGRect(x: 0, y: 0, width: size.width, height: horizonY))
            UIColor(red: 0.36, green: 0.56, blue: 0.29, alpha: 1).setFill()
            c.fill(CGRect(x: 0, y: horizonY, width: size.width, height: size.height - horizonY))

            // Optional lid at the base
            if let b = display(base) {
                let w = 0.58 * pxPerMetre, h = max(2, w * 0.18)
                UIColor(white: 0.62, alpha: 1).setFill()
                c.fillEllipse(in: CGRect(x: b.x - w / 2, y: b.y - h / 2, width: w, height: h))
            }
            // Guy lines to three stakes, 1.75 m out, tied at three-quarters height
            if let tie = display(base + SIMD3(0, H * 0.75, 0)) {
                c.setStrokeColor(UIColor(white: 0.95, alpha: 0.7).cgColor)
                c.setLineWidth(max(1, 1.5 * scale))
                for deg in [30.0, 150.0, 270.0] {
                    let a = deg * .pi / 180
                    if let stake = display(base + SIMD3(1.75 * cos(a), 0, 1.75 * sin(a))) {
                        c.move(to: tie); c.addLine(to: stake); c.strokePath()
                    }
                }
            }
            // The pole, with its 4 in orange tip band
            if let b = display(base), let t = display(base + SIMD3(0, H, 0)),
               let band = display(base + SIMD3(0, H - 0.1016, 0)) {
                c.setLineCap(.butt)
                c.setLineWidth(max(2, 0.038 * pxPerMetre))
                c.setStrokeColor(UIColor(red: 0.80, green: 0.66, blue: 0.43, alpha: 1).cgColor)
                c.move(to: b); c.addLine(to: band); c.strokePath()
                c.setStrokeColor(UIColor(red: 0.95, green: 0.42, blue: 0.11, alpha: 1).cgColor)
                c.move(to: band); c.addLine(to: t); c.strokePath()
            }
            // Label
            let label = "SIMULATED CAMERA" as NSString
            label.draw(at: CGPoint(x: 12 * max(scale, 0.5), y: 12 * max(scale, 0.5)),
                       withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 28 * max(scale, 0.5), weight: .semibold),
                                        .foregroundColor: UIColor(white: 0, alpha: 0.55)])
        }
        return image.cgImage
    }
}
