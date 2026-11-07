import SwiftUI
import CoreMotion
import RangingKit

/// Reads the phone's gravity vector, smoothed, and turns it into pole lean.
final class LeanMeter: ObservableObject {
    @Published private(set) var current: LeanReading?
    @Published private(set) var available = true
    private let motion = CMMotionManager()
    private var smoothed: SIMD3<Double>?

    func start() {
        guard motion.isDeviceMotionAvailable else { available = false; return }
        motion.deviceMotionUpdateInterval = 1.0 / 50
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let g = data?.gravity else { return }
            let v = SIMD3(g.x, g.y, g.z)
            // Exponential smoothing over roughly a second.
            self.smoothed = self.smoothed.map { $0 + ($0 - v) * -0.04 } ?? v
            self.current = self.smoothed.flatMap { LeanMath.reading(gravity: $0) }
        }
    }

    func stop() { motion.stopDeviceMotionUpdates() }
}

struct LeanCheckView: View {
    @StateObject private var meter = LeanMeter()
    @State private var faceA: LeanReading?
    @State private var faceB: LeanReading?

    private var result: (lean: LeanReading, bias: LeanReading)? {
        guard let a = faceA, let b = faceB else { return nil }
        return LeanMath.twoFace(a, b)
    }

    var body: some View {
        List {
            Section {
                Text("Hold the back of the phone flat against the pole, top of the phone pointing up. Record one face, then turn to the opposite face of the pole and record again. Averaging the two cancels the phone's own sensor error.")
                    .font(.callout)
            }

            Section("Live reading (one face, uncorrected)") {
                if !meter.available {
                    Text("Motion sensors aren't available on this device.")
                } else if let r = meter.current {
                    reading(r)
                } else {
                    Text("Point the top of the phone up.").foregroundStyle(.secondary)
                }
            }

            Section("Two-face check") {
                HStack {
                    Button(faceA == nil ? "Record face 1" : "Face 1 recorded") { faceA = meter.current }
                        .disabled(meter.current == nil)
                    Spacer()
                    Button(faceB == nil ? "Record face 2" : "Face 2 recorded") { faceB = meter.current }
                        .disabled(meter.current == nil || faceA == nil)
                }
                .buttonStyle(.bordered)

                if let r = result {
                    let ok = r.lean.total < LeanMath.limitDegrees
                    HStack {
                        Text(String(format: "%.2f°", r.lean.total))
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Spacer()
                        Text(ok ? "Plumb" : "Adjust guy lines")
                            .font(.headline)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(ok ? Color.green.opacity(0.2) : Color.orange.opacity(0.25), in: Capsule())
                    }
                    Text(String(format: "Toward face 1's right edge %+.2f°, toward face 1's screen side %+.2f°",
                                r.lean.across, r.lean.through))
                        .font(.footnote)
                    Text(String(format: "Phone sensor offset removed: %.2f°", r.bias.total))
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Start over") { faceA = nil; faceB = nil }
                }
            }
        }
        .navigationTitle("Lean check")
        .onAppear { meter.start() }
        .onDisappear { meter.stop() }
    }

    private func reading(_ r: LeanReading) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(format: "%.2f°", r.total))
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(String(format: "Right edge %+.2f° · screen side %+.2f°", r.across, r.through))
                .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}
