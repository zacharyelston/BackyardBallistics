import SwiftUI
import RangingKit

/// Sighting-test samples.
typealias FieldLogStore = JSONStore<FieldSample>

extension JSONStore where Item == FieldSample {
    func csvFile() -> URL { exportFile(named: "spudgungolf-sighting-log.csv", contents: FieldCSV.make(items)) }
}

struct FieldLogView: View {
    @EnvironmentObject private var log: FieldLogStore

    var body: some View {
        List {
            if log.items.isEmpty {
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
                    ForEach(log.items) { s in
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
            if !log.items.isEmpty {
                ShareLink(item: log.csvFile()) { Label("Export CSV", systemImage: "square.and.arrow.up") }
            }
        }
    }

    private var summary: [(lens: String, count: Int, meanAbsPct: Double)] {
        var groups: [String: [Double]] = [:]
        for s in log.items {
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
