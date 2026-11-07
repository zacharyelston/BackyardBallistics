import SwiftUI
import RangingKit

/// Sighting-test samples, saved as JSON in the app's Documents folder.
final class FieldLogStore: ObservableObject {
    @Published private(set) var samples: [FieldSample] = []

    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("fieldlog.json")
    }

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([FieldSample].self, from: data) {
            samples = saved
        }
    }

    func add(_ s: FieldSample) {
        samples.insert(s, at: 0)
        save()
    }

    func delete(at offsets: IndexSet) {
        samples.remove(atOffsets: offsets)
        save()
    }

    private func save() {
        try? JSONEncoder().encode(samples).write(to: fileURL, options: .atomic)
    }

    /// Writes the log as CSV to a temporary file for sharing.
    func csvFile() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spudgungolf-sighting-log.csv")
        try? FieldCSV.make(samples).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

struct FieldLogView: View {
    @EnvironmentObject private var log: FieldLogStore

    var body: some View {
        List {
            if log.samples.isEmpty {
                Text("No samples yet. Run the sighting test from a few taped distances: 10, 30, 60 and 90 m.")
                    .foregroundStyle(.secondary)
            } else {
                Section("By lens") {
                    ForEach(summary, id: \.lens) { row in
                        LabeledContent(row.lens) {
                            Text(String(format: "%d samples · mean |error| %.1f%%", row.count, row.meanAbsPct)).monospacedDigit()
                        }
                    }
                }
                Section("Samples") {
                    ForEach(log.samples) { s in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(s.lens).font(.headline)
                                Spacer()
                                if let pct = s.errorPercent {
                                    Text(String(format: "%+.1f%%", pct)).monospacedDigit()
                                        .foregroundStyle(abs(pct) < 2 ? .green : .orange)
                                }
                            }
                            Text(String(format: "Taped %@ · ranged %@ · %.0f px",
                                        s.trueDistance.map { Units.metres($0) } ?? "–",
                                        s.estimatedDistance.map { Units.metres($0) } ?? "–", s.polePixels))
                                .font(.footnote).foregroundStyle(.secondary)
                            if !s.note.isEmpty { Text(s.note).font(.footnote) }
                        }
                    }
                    .onDelete(perform: log.delete)
                }
            }
        }
        .navigationTitle("Field log")
        .toolbar {
            if !log.samples.isEmpty {
                ShareLink(item: log.csvFile()) { Label("Export CSV", systemImage: "square.and.arrow.up") }
            }
        }
    }

    private var summary: [(lens: String, count: Int, meanAbsPct: Double)] {
        var groups: [String: [Double]] = [:]
        for s in log.samples {
            if let pct = s.errorPercent { groups[s.lens, default: []].append(abs(pct)) }
        }
        var rows: [(lens: String, count: Int, meanAbsPct: Double)] = []
        for (lens, errors) in groups {
            let mean: Double = errors.reduce(0, +) / Double(errors.count)
            rows.append((lens: lens, count: errors.count, meanAbsPct: mean))
        }
        return rows.sorted { $0.lens < $1.lens }
    }
}
