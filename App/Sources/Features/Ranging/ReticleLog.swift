import SwiftUI
import RangingKit

/// One reticle lock, kept with everything recorded at the lock so it can be re-checked later.
struct ReticleRecord: Codable, Identifiable {
    var id = UUID()
    var lock: ReticleLock
    var trueDistance: Double?
    var gateMiss: Double?
    var note: String

    var error: Double? { trueDistance.map { lock.range - $0 } }
}

/// Reticle rangings (the main method).
typealias ReticleLogStore = JSONStore<ReticleRecord>

extension JSONStore where Item == ReticleRecord {
    func csvFile() -> URL {
        let iso = ISO8601DateFormatter()
        func n(_ v: Double?, _ d: Int = 3) -> String { v.map { String(format: "%.\(d)f", $0) } ?? "" }
        var lines = ["date,true_m,est_m,error_m,sigma_m,line_px,focal_px,pole_h_m,angle_below_deg,bearing_deg,height_diff_m,camera_h_m,lat,lon,gps_acc_m,pole_lat,pole_lon,gate_miss_m,note"]
        for r in items {
            let l = r.lock
            lines.append([iso.string(from: l.date), n(r.trueDistance), n(l.range), n(r.error), n(l.sigma),
                          n(l.linePixels, 1), n(l.reticle.focalPixels, 1), n(l.reticle.poleHeight),
                          n(l.angleBelowLevel, 3), n(l.bearing, 1), n(l.heightDifference), n(l.cameraHeight),
                          n(l.location.latitude, 7), n(l.location.longitude, 7), n(l.horizontalAccuracy, 1),
                          n(l.polePosition.latitude, 7), n(l.polePosition.longitude, 7), n(r.gateMiss, 1),
                          "\"" + r.note.replacingOccurrences(of: "\"", with: "\"\"") + "\""].joined(separator: ","))
        }
        return exportFile(named: "spudgungolf-reticle-log.csv", contents: lines.joined(separator: "\n") + "\n")
    }
}

struct ReticleLogView: View {
    @EnvironmentObject private var log: ReticleLogStore

    var body: some View {
        List {
            if log.items.isEmpty {
                Text("No reticle locks logged yet. Lock on the pole from taped distances and log each one.")
                    .foregroundStyle(.secondary)
            }
            ForEach(log.items) { r in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("\(Units.metres(r.lock.range)) ± \(Units.metres(r.lock.sigma))").font(.headline).monospacedDigit()
                        Spacer()
                        if let e = r.error {
                            Text(String(format: "%+.2f m", e)).monospacedDigit()
                                .foregroundStyle(abs(e) <= max(2 * r.lock.sigma, 0.05) ? .green : .orange)
                        }
                    }
                    Text(String(format: "Taped %@ · %.0f px line · %.1f° down · bearing %.0f°",
                                r.trueDistance.map { Units.metres($0) } ?? "–", r.lock.linePixels,
                                r.lock.angleBelowLevel, r.lock.bearing))
                        .font(.footnote).foregroundStyle(.secondary)
                    if !r.note.isEmpty { Text(r.note).font(.footnote) }
                }
            }
            .onDelete(perform: log.delete)
        }
        .navigationTitle("Reticle log")
        .toolbar {
            if !log.items.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: log.csvFile()) { Label("Export CSV", systemImage: "square.and.arrow.up") }
                }
            }
        }
    }
}
