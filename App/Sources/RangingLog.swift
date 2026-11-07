import SwiftUI
import RangingKit

/// One multi-photo ranging, with the raw sightings kept so it can be re-solved later.
struct RangingRecord: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var distance: Double
    var sigma: Double
    var heightDifference: Double
    var baseline: Double
    var photos: Int
    var dropped: Int
    var maxDisagreementPercent: Double
    var trueDistance: Double?
    var gateMiss: Double?
    var poleHeight: Double
    var cameraHeight: Double
    var note: String
    var sightings: [PoleSighting]

    init(report r: RangeReport, sightings: [PoleSighting], trueDistance: Double?, gateMiss: Double?,
         poleHeight: Double, cameraHeight: Double, note: String) {
        distance = r.distance; sigma = r.distanceSigma; heightDifference = r.heightDifference
        baseline = r.baseline; photos = r.photoCount; dropped = r.droppedCount
        maxDisagreementPercent = r.maxDisagreementPercent
        self.trueDistance = trueDistance; self.gateMiss = gateMiss
        self.poleHeight = poleHeight; self.cameraHeight = cameraHeight
        self.note = note; self.sightings = sightings
    }

    var error: Double? { trueDistance.map { distance - $0 } }
}

final class RangingLogStore: ObservableObject {
    @Published private(set) var records: [RangingRecord] = []

    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ranginglog.json")
    }

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([RangingRecord].self, from: data) {
            records = saved
        }
    }

    func add(_ r: RangingRecord) { records.insert(r, at: 0); save() }
    func delete(at offsets: IndexSet) { records.remove(atOffsets: offsets); save() }

    private func save() { try? JSONEncoder().encode(records).write(to: fileURL, options: .atomic) }

    func csvFile() -> URL {
        let iso = ISO8601DateFormatter()
        func n(_ v: Double?, _ d: Int = 3) -> String { v.map { String(format: "%.\(d)f", $0) } ?? "" }
        var lines = ["date,true_m,est_m,error_m,sigma_m,height_diff_m,baseline_m,photos,dropped,max_disagree_pct,gate_miss_m,pole_h_m,camera_h_m,note"]
        for r in records {
            lines.append([iso.string(from: r.date), n(r.trueDistance), n(r.distance), n(r.error), n(r.sigma),
                          n(r.heightDifference), n(r.baseline, 2), "\(r.photos)", "\(r.dropped)",
                          n(r.maxDisagreementPercent, 2), n(r.gateMiss, 1), n(r.poleHeight), n(r.cameraHeight),
                          "\"" + r.note.replacingOccurrences(of: "\"", with: "\"\"") + "\""].joined(separator: ","))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spudgungolf-ranging-log.csv")
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Full records including every sighting, for re-solving offline.
    func jsonFile() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spudgungolf-ranging-log.json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try? enc.encode(records).write(to: url, options: .atomic)
        return url
    }
}

struct RangingLogView: View {
    @EnvironmentObject private var log: RangingLogStore

    var body: some View {
        List {
            if log.records.isEmpty {
                Text("No rangings logged yet. Range the flag from taped distances and log each one.")
                    .foregroundStyle(.secondary)
            }
            ForEach(log.records) { r in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("\(Units.metres(r.distance)) ± \(Units.metres(r.sigma))").font(.headline).monospacedDigit()
                        Spacer()
                        if let e = r.error {
                            Text(String(format: "%+.2f m", e)).monospacedDigit()
                                .foregroundStyle(abs(e) <= max(2 * r.sigma, 0.05) ? .green : .orange)
                        }
                    }
                    Text(String(format: "Taped %@ · %d photos · baseline %.1f m · %+.2f m height",
                                r.trueDistance.map { Units.metres($0) } ?? "–", r.photos, r.baseline, r.heightDifference))
                        .font(.footnote).foregroundStyle(.secondary)
                    if !r.note.isEmpty { Text(r.note).font(.footnote) }
                }
            }
            .onDelete(perform: log.delete)
        }
        .navigationTitle("Ranging log")
        .toolbar {
            if !log.records.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ShareLink("Export CSV", item: log.csvFile())
                        ShareLink("Export full JSON", item: log.jsonFile())
                    } label: { Label("Export", systemImage: "square.and.arrow.up") }
                }
            }
        }
    }
}
