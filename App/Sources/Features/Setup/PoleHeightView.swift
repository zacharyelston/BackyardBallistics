import SwiftUI
import ARKit
import RealityKit
import RangingKit

/// Measures a pole's height with ARKit: tap the base on the ground, then tap the tip.
final class PoleHeightModel: ObservableObject {
    enum Step { case base, tip, done }
    @Published var step: Step = .base
    @Published var height: Double?
    @Published var message = "Stand 2–3 m from the pole. Move the phone slowly until the ground is tracked, then tap the base of the pole."

    func reset() {
        step = .base
        height = nil
        message = "Tap the base of the pole."
        resetHandler?()
    }

    var resetHandler: (() -> Void)?
}

struct PoleHeightView: View {
    @StateObject private var model = PoleHeightModel()
    @AppStorage(Settings.poleHeightKey) private var poleHeight = Settings.defaultPoleHeight
    @State private var saved = false

    var body: some View { cameraContent.cameraNeedsPortrait() }

    @ViewBuilder private var cameraContent: some View {
        ZStack(alignment: .bottom) {
            ARPoleView(model: model)
                .ignoresSafeArea(edges: .bottom)

            VStack(spacing: 10) {
                Text(model.message).font(.callout).multilineTextAlignment(.center)
                if let h = model.height {
                    Text(Units.metres(h)).font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                    Text(Units.feetInches(h)).foregroundStyle(.secondary)
                    HStack {
                        Button("Measure again") { model.reset(); saved = false }
                            .buttonStyle(.bordered)
                        Button(saved ? "Saved" : "Use as pole height") {
                            poleHeight = (h * 1000).rounded() / 1000
                            saved = true
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(saved)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(.regularMaterial)
        }
        .navigationTitle("Pole height")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ARPoleView: UIViewRepresentable {
    @ObservedObject var model: PoleHeightModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        view.session.run(config)
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:))))
        context.coordinator.view = view
        model.resetHandler = { [weak coordinator = context.coordinator] in coordinator?.clearMarkers() }
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    final class Coordinator: NSObject {
        let model: PoleHeightModel
        weak var view: ARView?
        private var base: SIMD3<Float>?
        private var anchors: [AnchorEntity] = []

        init(model: PoleHeightModel) { self.model = model }

        func clearMarkers() {
            anchors.forEach { $0.removeFromParent() }
            anchors.removeAll()
            base = nil
        }

        @objc func tap(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            let point = gesture.location(in: view)
            switch model.step {
            case .base:
                guard let hit = view.raycast(from: point, allowing: .estimatedPlane, alignment: .horizontal).first else {
                    model.message = "No ground found there yet. Move the phone a little and tap the base again."
                    return
                }
                let p = SIMD3<Float>(hit.worldTransform.columns.3.x, hit.worldTransform.columns.3.y, hit.worldTransform.columns.3.z)
                base = p
                addMarker(at: p)
                model.step = .tip
                model.message = "Now tap the orange tip of the pole."
            case .tip:
                guard let base, let ray = view.ray(through: point) else { return }
                let h = PoleGeometry.height(base: SIMD3<Double>(base), tipRayOrigin: SIMD3<Double>(ray.origin),
                                            tipRayDirection: SIMD3<Double>(ray.direction))
                guard let h, h > 0.3 else {
                    model.message = "That tap didn't line up with the pole. Tap the tip again."
                    return
                }
                addMarker(at: base + SIMD3<Float>(0, Float(h), 0))
                model.height = h
                model.step = .done
                model.message = "Measured. Repeat from another side and compare; they should agree within 2 cm."
            case .done:
                break
            }
        }

        private func addMarker(at p: SIMD3<Float>) {
            guard let view else { return }
            let anchor = AnchorEntity(world: p)
            anchor.addChild(ModelEntity(mesh: .generateSphere(radius: 0.02),
                                        materials: [SimpleMaterial(color: .orange, isMetallic: false)]))
            view.scene.addAnchor(anchor)
            anchors.append(anchor)
        }
    }
}
