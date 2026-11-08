import SwiftUI
import UIKit
import CourseKit
import GroupKit

/// The commander's inbox: field notes from members (also pinned on the map), and fields members
/// surveyed and sent in, to adopt for the squad or decline. Adopting is refused mid-hole, while
/// walking out, or in a started match; the reason shows here.
struct SquadInboxPanel: View {
    @EnvironmentObject private var command: SquadCommand
    @State private var enlarged: FieldNote?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Inbox").font(.headline)
            if let host = command.host {
                fields(host)
                notes(host)
                if host.notes.isEmpty && host.submissions.isEmpty {
                    Text("Nothing yet. Members send field notes and surveyed fields from their phones.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .sheet(item: $enlarged) { note in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let data = note.photo, let image = UIImage(data: data) {
                            Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        Text(note.text)
                    }
                    .padding()
                }
                .navigationTitle(note.author)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { enlarged = nil } } }
            }
        }
    }

    // MARK: Fields

    @ViewBuilder private func fields(_ host: SquadHost) -> some View {
        if !host.submissions.isEmpty {
            Text("Fields sent in").font(.subheadline.weight(.semibold))
            ForEach(host.submissions.reversed()) { f in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Label(f.course.name, systemImage: "map").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(f.course.holes.count) hole\(f.course.holes.count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("From \(f.author) · \(SquadOrdersPanel.age(f.time, now: Date()))")
                        .font(.caption).foregroundStyle(.secondary)
                    if let note = f.note, !note.isEmpty { Text(note).font(.footnote) }
                    HStack {
                        Button("Adopt") { command.adoptField(f.id) }.buttonStyle(.borderedProminent)
                        Button("Decline", role: .destructive) { command.declineField(f.id) }.buttonStyle(.bordered)
                    }
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
            }
            Text("Adopting starts a fresh card on the new field. Only between holes.")
                .font(.caption).foregroundStyle(.secondary)
            if let problem = host.lastProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red)
            }
        }
    }

    // MARK: Notes

    @ViewBuilder private func notes(_ host: SquadHost) -> some View {
        if !host.notes.isEmpty {
            Text("Field notes").font(.subheadline.weight(.semibold))
            TimelineView(.periodic(from: .now, by: 10)) { context in
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(host.notes.suffix(12).reversed()) { n in
                        Button { enlarged = n } label: { noteRow(n, now: context.date) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func noteRow(_ n: FieldNote, now: Date) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if let data = n.photo, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(n.author).font(.footnote.weight(.semibold))
                    if n.at != nil { Image(systemName: "mappin").font(.caption2).foregroundStyle(.yellow) }
                    Spacer()
                    Text(SquadOrdersPanel.age(n.time, now: now)).font(.caption).foregroundStyle(.secondary)
                }
                if !n.text.isEmpty { Text(n.text).font(.footnote).lineLimit(3) }
            }
        }
        .contentShape(Rectangle())
    }
}
