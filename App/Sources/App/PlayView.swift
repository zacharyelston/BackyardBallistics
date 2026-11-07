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
        Step(id: 1, title: "Load a course", detail: "Join the course Wi-Fi; the app downloads it from the course server.", milestone: 3, ready: false),
        Step(id: 2, title: "Confirm downrange", detail: DownrangeLog.prompt, milestone: 6, ready: false),
        Step(id: 3, title: "Range the pole", detail: "Crosshair on the base, dial the plumb line to the pole's top, lock.", milestone: 2, ready: true),
        Step(id: 4, title: "Initial data", detail: "Charge, elevation and aim, cleared by the safety checks.", milestone: 4, ready: false),
        Step(id: 5, title: "Fire and spot", detail: "Call short, over or range correct; left/right is measured with the crosshair.", milestone: 4, ready: false),
        Step(id: 6, title: "Adjust or cease fire", detail: "Add or drop, left or right, until a round rests in the ring.", milestone: 4, ready: false),
        Step(id: 7, title: "Verify and score", detail: "Walk out together; score is rounds plus metres outside the ring.", milestone: 6, ready: false)
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
                    Text("Each hole: a fire mission")
                } footer: {
                    Text("Ranging works now from the Tools tab. Course loading and scoring come in milestones 3 and 6.")
                }
                Section {
                    NavigationLink { ReticleRangingView() } label: {
                        Label("Range a pole now", systemImage: "scope")
                    }
                }
            }
            .navigationTitle("Play")
        }
    }
}
