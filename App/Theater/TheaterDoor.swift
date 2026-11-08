import SwiftUI
import AppKit
import CoreGeo
import GroupKit
import GroupLink
import FieldKit
import TheaterKit

// The Theater's door for phones (path 2 in GroupKit's FieldNotes.swift). On launch the Theater
// advertises itself on the local network under the Mac's name, with its own code. A phone picks
// "Send to Theater", enters the code, and sends fields, notes and capture files; TheaterKit's
// TheaterHost saves them under the field's folder. Nothing here carries firing data.

extension TheaterModel {
    /// TXT `role` of the Theater's door, so squad browsers can tell it from a squad.
    static let doorRole = "theater"
    private static let doorCodeKey = "theaterDoorCode"

    static var hostName: String { Host.current().localizedName ?? "Theater" }

    /// The door's code, kept across launches so phones don't need a new one.
    static func savedDoorCode() -> String {
        if let c = UserDefaults.standard.string(forKey: doorCodeKey), JoinCode.normalized(c).count == 6 { return c }
        let c = JoinCode.make()
        UserDefaults.standard.set(c, forKey: doorCodeKey)
        return c
    }

    /// Opens (or reopens) the door with the current code. GroupHost restarts itself after a failure.
    func openDoor() {
        door?.stop()
        door = nil
        theater = TheaterHost(name: Self.hostName, joinCode: doorCode, store: store)
        publishDoor()
        do {
            let host = try GroupHost(name: Self.hostName, joinCode: doorCode,
                                     txt: [GroupService.Key.role: Self.doorRole], queue: .main)
            host.onMessage = { [weak self] m, peer in MainActor.assumeIsolated { self?.doorReceived(m, from: peer) } }
            host.onPeerClosed = { [weak self] peer in
                MainActor.assumeIsolated {
                    self?.theater.peerClosed(peer)
                    self?.publishDoor()
                }
            }
            host.onReady = { [weak self] port in MainActor.assumeIsolated { self?.doorStatus = "Open on port \(port)" } }
            host.onFailed = { [weak self] e in MainActor.assumeIsolated { self?.doorStatus = "Restarting: \(e)" } }
            door = host
            host.start()
        } catch {
            doorStatus = "Couldn't open: \(error.localizedDescription)"
        }
    }

    /// A new code: phones connected with the old one are dropped and need the new one.
    func newDoorCode() {
        let c = JoinCode.make()
        UserDefaults.standard.set(c, forKey: Self.doorCodeKey)
        doorCode = c
        openDoor()
    }

    private func doorReceived(_ m: GroupMessage, from peer: PeerID) {
        let out = theater.handle(m, from: peer, now: Date())
        door?.send(out)
        publishDoor()
        if case .fieldSubmission = m.body { reloadFields() }
        let stored = out.contains { if case let .receipt(r) = $0.body { return r.status == .stored } else { return false } }
        if stored { refreshFieldContent() }
    }

    func publishDoor() {
        let names = theater.contributors.values.map(\.name).sorted()
        if names != contributors { contributors = names }
        if theater.activity != activity { activity = theater.activity }
    }

    /// A note's full-size photo, if a phone sent one (`notes/<note id>/<file>`).
    static func fullPhoto(for note: FieldNote, courseID: String?, in store: FieldStore) -> URL? {
        let dir = store.courseDirectory(courseID ?? TheaterHost.unfiled)
            .appendingPathComponent("notes/\(note.id.uuidString)", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return files.first { ["jpg", "jpeg", "heic", "png"].contains($0.pathExtension.lowercased()) }
    }

    /// The shown field's notes and capture targets, as pins for the site map.
    var mapNotes: [FieldNote] {
        shownNotes.map(\.note) + shownCaptures.compactMap { c in
            guard let t = c.target else { return nil }
            return FieldNote(id: c.pinID, author: "Capture", time: c.modified, courseID: contentCourseID, at: t,
                             accuracy: c.plusMinus, text: "Capture target" + (c.plusMinus.map { String(format: " ± %.1f m", $0) } ?? ""))
        }
    }

    var unfiledFolder: URL { store.courseDirectory(TheaterHost.unfiled) }
}

/// A saved note, with its small photo and full-size one if any.
struct ShownNote: Identifiable, Equatable {
    var note: FieldNote
    var photo: URL?
    var fullPhoto: URL?
    var id: UUID { note.id }
}

/// One capture bundle a phone sent: `<field>/captures/<group>/`.
struct CaptureGroup: Identifiable, Equatable {
    var id: String { folder.lastPathComponent }
    var folder: URL
    var files: Int
    var modified: Date
    var target: GeoPoint?
    var plusMinus: Double?
    /// Stable ID for its map pin.
    var pinID: UUID { UUID(uuidString: folder.lastPathComponent) ?? UUID(uuid: UUID_NULL) }

    /// The parts of the phone's `capture.json` (TargetCaptureBundle) the Theater shows.
    private struct Target: Decodable {
        var target: GeoPoint?
        var targetPlusMinus: Double?
    }

    static func all(in store: FieldStore, courseID: String) -> [CaptureGroup] {
        let fm = FileManager.default
        let root = store.courseDirectory(courseID).appendingPathComponent("captures", isDirectory: true)
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                options: [.skipsHiddenFiles])) ?? []
        return dirs.compactMap { dir -> CaptureGroup? in
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles])) ?? []
            let modified = files.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
                ?? .distantPast
            let t = (try? Data(contentsOf: dir.appendingPathComponent("capture.json")))
                .flatMap { try? JSONDecoder().decode(Target.self, from: $0) }
            return CaptureGroup(folder: dir, files: files.count, modified: modified, target: t?.target,
                                plusMinus: t?.target == nil ? nil : t?.targetPlusMinus)
        }
        .sorted { $0.modified > $1.modified }
    }
}

// MARK: Views

/// Top of the sidebar: the door's code, who is connected, and what came in lately.
struct DoorSection: View {
    @EnvironmentObject private var model: TheaterModel
    @State private var confirmingNewCode = false

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("On a phone: Send to Theater, then pick \(TheaterModel.hostName) and enter")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(spaced(model.doorCode))
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button("New code") { confirmingNewCode = true }
                        .help("Make a new code. Phones connected with this one are dropped.")
                }
                Text(model.doorStatus).font(.caption2).foregroundStyle(.tertiary)
                if model.contributors.isEmpty {
                    Text("No phones connected.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Label(model.contributors.joined(separator: ", "), systemImage: "iphone")
                        .font(.caption)
                }
                if !model.activity.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.activity.suffix(5).reversed().enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                if FileManager.default.fileExists(atPath: model.unfiledFolder.path) {
                    Button("Notes and files with no field…") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.unfiledFolder])
                    }
                    .buttonStyle(.link).font(.caption)
                }
            }
            .padding(.vertical, 2)
            .selectionDisabled()
        } header: {
            Text("Phones")
        }
        .confirmationDialog("Make a new Theater code?", isPresented: $confirmingNewCode) {
            Button("New code") { model.newDoorCode() }
        } message: {
            Text("Phones connected now are dropped, and every phone needs the new code to send to this Theater.")
        }
    }

    private func spaced(_ code: String) -> String {
        let c = JoinCode.normalized(code)
        return c.count == 6 ? "\(c.prefix(3)) \(c.suffix(3))" : c
    }
}

/// The shown field's notes (newest first) and capture bundles, under its header.
struct FieldContentView: View {
    @EnvironmentObject private var model: TheaterModel
    let courseID: String
    @State private var enlarged: EnlargedPhoto?

    struct EnlargedPhoto: Identifiable {
        var url: URL
        var caption: String
        var id: URL { url }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.shownNotes.isEmpty {
                GroupBox("Notes (\(model.shownNotes.count))") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.shownNotes.prefix(30)) { NoteRow(item: $0, enlarge: { enlarged = $0 }) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !model.shownCaptures.isEmpty {
                GroupBox("Captures (\(model.shownCaptures.count))") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.shownCaptures) { c in
                            HStack(spacing: 8) {
                                Image(systemName: "camera.viewfinder")
                                Text(c.modified.formatted(date: .abbreviated, time: .shortened))
                                Text("\(c.files) file\(c.files == 1 ? "" : "s")").foregroundStyle(.secondary)
                                if let t = c.target {
                                    Text(String(format: "target %.6f, %.6f", t.latitude, t.longitude)
                                         + (c.plusMinus.map { String(format: " ± %.1f m", $0) } ?? ""))
                                        .monospacedDigit().foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([c.folder]) }
                                    .buttonStyle(.link)
                            }
                            .font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .sheet(item: $enlarged) { p in
            VStack(spacing: 8) {
                if let image = NSImage(contentsOf: p.url) {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Text("Couldn't open the photo.").foregroundStyle(.secondary)
                }
                HStack {
                    Text(p.caption).font(.caption).lineLimit(2)
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([p.url]) }
                    Button("Close") { enlarged = nil }.keyboardShortcut(.cancelAction)
                }
            }
            .padding()
            .frame(minWidth: 640, idealWidth: 900, minHeight: 480, idealHeight: 700)
        }
    }
}

private struct NoteRow: View {
    let item: ShownNote
    let enlarge: (FieldContentView.EnlargedPhoto) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let thumb = item.photo ?? item.fullPhoto, let image = NSImage(contentsOf: thumb) {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .onTapGesture { enlarge(.init(url: item.fullPhoto ?? thumb, caption: caption)) }
                    .help("Open the photo")
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.note.author).fontWeight(.semibold)
                    Text(item.note.time.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                    if item.note.at != nil { Image(systemName: "mappin").foregroundStyle(.yellow).help("On the map") }
                }
                .font(.caption)
                Text(item.note.text).font(.callout).textSelection(.enabled)
            }
        }
    }

    private var caption: String { "\(item.note.author), \(item.note.time.formatted(date: .abbreviated, time: .shortened)): \(item.note.text)" }
}
