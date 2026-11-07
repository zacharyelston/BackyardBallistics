import SwiftUI
import SafetyKit

/// The round. Today it lays out the hole loop and links to the parts already built;
/// course loading (milestone 3) and scoring (milestone 6) fill it in.
struct PlayView: View {
    private struct Step: Identifiable {
        let id: Int
        let title: String
        let detail: String
        let milestone: Int
        let ready: Bool
    }

    private let steps = [
        Step(id: 1, title: "Load a course", detail: "From a link or the QR sign at the first start spot.", milestone: 3, ready: false),
        Step(id: 2, title: "Confirm downrange", detail: DownrangeLog.prompt, milestone: 6, ready: false),
        Step(id: 3, title: "Read the wind", detail: "Telltales on the guy lines and the windsock on top.", milestone: 4, ready: false),
        Step(id: 4, title: "Range the flag", detail: "Three to five photos of the pole from a short arc.", milestone: 2, ready: true),
        Step(id: 5, title: "Get a solution", detail: "Charge, elevation and aim, cleared by the safety checks.", milestone: 4, ready: false),
        Step(id: 6, title: "Fire, walk, log", detail: "Tap the lie, range again, and the shot teaches the wind.", milestone: 6, ready: false),
        Step(id: 7, title: "Hole out", detail: "Counts when the potato rests on the lid or against the pole.", milestone: 6, ready: false)
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(steps) { step in
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(step.id)")
                                .font(.headline.monospacedDigit())
                                .frame(width: 26, height: 26)
                                .background(step.ready ? Color.orange.opacity(0.25) : Color.secondary.opacity(0.15), in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.title).font(.headline)
                                Text(step.detail).font(.footnote).foregroundStyle(.secondary)
                                if !step.ready {
                                    Text("Milestone \(step.milestone)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Each hole")
                } footer: {
                    Text("Ranging works now from the Tools tab. Course loading and scoring come in milestones 3 and 6.")
                }
                Section {
                    NavigationLink { RangingView() } label: {
                        Label("Range a flag now", systemImage: "camera.metering.multispot")
                    }
                }
            }
            .navigationTitle("Play")
        }
    }
}
