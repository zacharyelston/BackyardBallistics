import SwiftUI
import GroupKit

/// Which Theater to send to, its code, and the link's state. Sections for a `Form`.
struct TheaterPickerSections: View {
    @EnvironmentObject private var theater: TheaterLink
    @State private var code = ""

    var body: some View {
        Section {
            if theater.found.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Looking for a Theater host on this Wi-Fi…").foregroundStyle(.secondary)
                }
            }
            ForEach(theater.found) { f in
                Button {
                    theater.theaterName = f.name
                } label: {
                    HStack {
                        Label(f.name, systemImage: "theatermasks.fill")
                        Spacer()
                        if !f.isCompatible {
                            Text("Other version").font(.caption).foregroundStyle(.orange)
                        } else if theater.theaterName == f.name {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                .foregroundStyle(.primary)
                .disabled(!f.isCompatible)
            }
            if let name = theater.theaterName, !theater.found.contains(where: { $0.name == name }) {
                Label("\(name) (not seen yet)", systemImage: "theatermasks").foregroundStyle(.secondary)
            }
            if let error = theater.browseError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Theater")
        } footer: {
            Text("The course owner's Mac. Your phone and the Theater need to be on the same Wi-Fi.")
        }
        if let name = theater.theaterName {
            Section {
                if let saved = theater.code(for: name), code.isEmpty {
                    LabeledContent("Code", value: saved)
                    Button("Change code") { code = saved }
                } else {
                    TextField("6-character code", text: $code)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .font(.body.monospaced())
                    Button("Save code") { theater.setCode(code, for: name); code = "" }
                        .disabled(JoinCode.normalized(code).count != 6)
                }
                TheaterStateLabel()
            } header: {
                Text("\(name)'s code")
            } footer: {
                Text("Shown on the Theater's screen. Asked once; this phone remembers it.")
            }
        }
    }
}

/// The link's state, one line.
struct TheaterStateLabel: View {
    @EnvironmentObject private var theater: TheaterLink

    var body: some View {
        switch theater.state {
        case .idle:
            Label("Not linked (links when you send)", systemImage: "antenna.radiowaves.left.and.right.slash")
                .foregroundStyle(.secondary).font(.footnote)
        case let .connecting(name):
            Label("Linking to \(name)…", systemImage: "antenna.radiowaves.left.and.right").font(.footnote)
        case let .connected(name):
            Label("Linked to \(name)", systemImage: "antenna.radiowaves.left.and.right").foregroundStyle(.green).font(.footnote)
        case let .reconnecting(why):
            Label("Relinking: \(why)", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.orange).font(.footnote)
        case let .failed(why):
            Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.footnote)
        }
    }
}

/// One sent item: its progress and what the receiver did with it.
struct SentItemRow: View {
    let title: String
    var progress: Double?
    var receipt: Receipt?
    var failed: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline).lineLimit(1)
                Spacer()
                ReceiptBadge(receipt: receipt, failed: failed, sending: progress.map { $0 < 1 } ?? false)
            }
            if let progress, receipt == nil, failed == nil {
                ProgressView(value: progress)
            }
            if let detail = failed ?? receipt?.detail, !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ReceiptBadge: View {
    var receipt: Receipt?
    var failed: String?
    var sending = false

    var body: some View {
        let (text, color): (String, Color) = {
            if failed != nil { return ("not sent", .red) }
            switch receipt?.status {
            case .stored: return ("stored", .green)
            case .received: return ("received", .blue)
            case .refused: return ("refused", .red)
            case nil: return (sending ? "sending" : "waiting", .secondary)
            }
        }()
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

/// Items sent to the Theater (all of them, or just `ids`).
struct TheaterItemsSection: View {
    @EnvironmentObject private var theater: TheaterLink
    var ids: [UUID]?
    var title = "Sent to the Theater"

    var body: some View {
        let shown = ids.map { ids in theater.items.filter { ids.contains($0.id) } } ?? theater.items
        if !shown.isEmpty {
            Section {
                ForEach(shown) { item in
                    SentItemRow(title: item.title, progress: item.progress, receipt: item.receipt, failed: item.failed)
                }
            } header: {
                Text(title)
            }
        }
    }
}

/// Send to Theater for one thing (a surveyed field, a capture): pick the Theater, Send, and follow
/// each piece's receipt.
struct TheaterSendView: View {
    @EnvironmentObject private var theater: TheaterLink
    let title: String
    /// What it sends, listed before sending.
    let summary: [String]
    let payloads: () -> [TheaterLink.Payload]
    @State private var sent: [UUID]?

    var body: some View {
        Form {
            Section {
                ForEach(summary, id: \.self) { Text($0) }
            } header: {
                Text("Sending")
            }
            TheaterPickerSections()
            Section {
                Button {
                    sent = theater.send(payloads())
                } label: {
                    Label(sent == nil ? "Send to Theater" : "Send again", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!theater.isReady)
            }
            if let sent { TheaterItemsSection(ids: sent, title: "Receipts") }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { theater.startBrowsing() }
        .onDisappear { theater.stopBrowsing() }
    }
}
