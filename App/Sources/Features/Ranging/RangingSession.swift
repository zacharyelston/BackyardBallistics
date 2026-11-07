import Foundation
import CoreGeo
import RangingKit

/// One ranging: the photos taken so far, how far the phone has moved, and where the lie is.
///
/// Talks only to a `RangingCaptureSource`, never to ARKit, so it behaves the same with the real
/// camera and with the simulated one.
final class RangingSession: ObservableObject {
    @Published var sightings: [PoleSighting] = []
    @Published private(set) var baseline: Double = 0
    @Published private(set) var tracking: CaptureTracking = .starting
    @Published private(set) var lieLocation: GeoPoint?
    @Published private(set) var currentLocation: GeoPoint?
    @Published private(set) var horizontalAccuracy: Double?

    let source: RangingCaptureSource

    init(source: RangingCaptureSource) {
        self.source = source
        source.onStatus = { [weak self] status in self?.apply(status) }
    }

    /// The real camera on a phone; the simulated one in the Simulator, on unsupported devices, or
    /// when the player turns it on in Tools.
    static func make(defaults: UserDefaults = .standard) -> RangingSession {
        let poleHeight = defaults.object(forKey: Settings.poleHeightKey) as? Double ?? Settings.defaultPoleHeight
        #if targetEnvironment(simulator)
        let simulated = true
        #else
        let simulated = defaults.bool(forKey: Settings.simulatedCaptureKey) || !ARKitRangingSource.isSupported
        #endif
        let source: RangingCaptureSource = simulated ? SimulatedRangingSource(poleHeight: poleHeight) : ARKitRangingSource()
        return RangingSession(source: source)
    }

    var trackingReady: Bool { tracking.ready }

    func start() { source.start() }
    func pause() { source.stop() }

    func reset() {
        sightings = []
        lieLocation = nil
        baseline = 0
    }

    func capture() -> FrozenFrame? { source.capture() }

    func add(_ sighting: PoleSighting) {
        if sightings.isEmpty { lieLocation = currentLocation }
        sightings.append(sighting)
        updateBaseline(sighting.pose.position)
    }

    private func apply(_ status: CaptureStatus) {
        tracking = status.tracking
        if let l = status.location { currentLocation = l }
        horizontalAccuracy = status.horizontalAccuracy
        if let p = status.cameraPosition { updateBaseline(p) }
    }

    /// Widest sideways spread from the first photo, which is what triangulation needs.
    private func updateBaseline(_ p: SIMD3<Double>) {
        guard let first = sightings.first?.pose.position else { return }
        baseline = max(baseline, ((p.x - first.x) * (p.x - first.x) + (p.z - first.z) * (p.z - first.z)).squareRoot())
    }
}
