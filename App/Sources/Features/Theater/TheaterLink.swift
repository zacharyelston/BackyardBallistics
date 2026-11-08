import Foundation
import SwiftUI
import GroupKit
import GroupLink

/// Send to Theater: any phone, in a squad or not, sends field notes, surveyed fields and capture
/// files straight to the course owner's Theater host. Finds Theater hosts on the Wi-Fi (TXT
/// `role=theater`), asks for the Theater's six-character code once per Theater, and keeps a
/// `GroupClient` up while anything is waiting to go or waiting for its receipt.
///
/// Nothing sent here carries firing data: notes, course files and capture photos only.
@MainActor
final class TheaterLink: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting(String)
        /// The Theater said hello back (its first receipt).
        case connected(String)
        case reconnecting(String)
        case failed(String)
    }

    /// Something to send.
    enum Payload {
        case note(FieldNote)
        case field(FieldSubmission)
        /// A file from disk, in chunks. `id` becomes the offer's ID, to match its receipt.
        case file(URL, kind: FileOffer.Kind, group: UUID, courseID: String?, id: UUID = UUID())
    }

    /// One thing sent, and what the Theater did with it.
    struct Item: Identifiable, Equatable {
        var id: UUID
        var title: String
        /// 0…1 while a file's chunks go out; nil for notes and fields.
        var progress: Double?
        var receipt: Receipt?
        var failed: String?
        var date: Date

        var isDone: Bool { receipt != nil || failed != nil }
    }

    @Published private(set) var found: [GroupBrowser.Found] = []
    @Published private(set) var browseError: String?
    @Published private(set) var state: State = .idle
    @Published private(set) var items: [Item] = []
    /// The Theater picked last time, sent to by default.
    @Published var theaterName: String? {
        didSet { UserDefaults.standard.set(theaterName, forKey: Self.nameKey) }
    }

    private var browser: GroupBrowser?
    private var client: GroupClient?
    private var clientTarget: (name: String, code: String)?
    private var queue: [Payload] = []
    private var sending = false
    private var idleStop: DispatchWorkItem?

    private static let nameKey = "theaterName"
    private static let codesKey = "theaterCodes"
    /// Drop the link this long after the last receipt arrives.
    static let idleAfter: TimeInterval = 20

    init() {
        theaterName = UserDefaults.standard.string(forKey: Self.nameKey)
    }

    // MARK: Finding Theaters

    func startBrowsing() {
        guard browser == nil else { return }
        browseError = nil
        let b = GroupBrowser()
        b.onChange = { [weak self] list in
            guard let self else { return }
            self.found = list.filter { $0.txt[GroupService.Key.role] == "theater" }
            if self.theaterName == nil, self.found.count == 1 { self.theaterName = self.found[0].name }
        }
        b.onFailed = { [weak self] error in self?.browseError = error }
        browser = b
        b.start()
    }

    func stopBrowsing() {
        browser?.stop()
        browser = nil
    }

    /// The code saved for a Theater, if it was typed before.
    func code(for name: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: Self.codesKey) as? [String: String])?[name]
    }

    func setCode(_ code: String, for name: String) {
        var codes = (UserDefaults.standard.dictionary(forKey: Self.codesKey) as? [String: String]) ?? [:]
        let c = JoinCode.normalized(code)
        codes[name] = c.isEmpty ? nil : c
        UserDefaults.standard.set(codes, forKey: Self.codesKey)
        if clientTarget?.name == name { disconnect() }   // a new code: reconnect with it
        objectWillChange.send()
    }

    /// A Theater is picked and has a code: Send can go.
    var isReady: Bool {
        guard let n = theaterName, let c = code(for: n) else { return false }
        return c.count == 6
    }

    // MARK: Sending

    /// Queues payloads and sends them as soon as the Theater is linked. Returns the item IDs, to
    /// follow their receipts.
    @discardableResult
    func send(_ payloads: [Payload]) -> [UUID] {
        var ids: [UUID] = []
        for p in payloads {
            let (id, title, progress) = Self.describe(p)
            items.insert(Item(id: id, title: title, progress: progress, date: Date()), at: 0)
            ids.append(id)
        }
        if items.count > 60 { items.removeLast(items.count - 60) }
        queue += payloads
        idleStop?.cancel()
        guard let name = theaterName, let code = code(for: name) else {
            fail(ids, "Pick a Theater and type its code first.")
            queue.removeAll()
            return ids
        }
        connect(name: name, code: code)
        flush()
        return ids
    }

    func item(_ id: UUID) -> Item? { items.first { $0.id == id } }

    /// Drops the link. Anything not yet answered is marked not sent.
    func disconnect() {
        tearDown()
        let waiting = items.filter { !$0.isDone }.map(\.id)
        fail(waiting, "The link closed before the Theater answered.")
        queue.removeAll()
    }

    /// Clears finished items from the list.
    func clearFinished() { items.removeAll { $0.isDone } }

    /// Closes the client without touching the queue or the items (switching Theater or code).
    private func tearDown() {
        let c = client
        client = nil
        clientTarget = nil
        c?.onStatus = nil
        c?.onMessage = nil
        c?.stop()
        state = .idle
    }

    private func connect(name: String, code: String) {
        if let t = clientTarget, t.name == name, t.code == code, client != nil { return }
        tearDown()
        clientTarget = (name, code)
        state = .connecting(name)
        let player = UserDefaults.standard.string(forKey: Settings.playerNameKey) ?? Settings.defaultPlayerName
        let c = GroupClient(squadName: name, joinCode: code,
                            hello: Hello(name: player, device: SquadMembership.deviceID, joinCode: code, role: .contributor))
        c.onStatus = { [weak self] s in self?.clientChanged(s, name: name) }
        c.onMessage = { [weak self] m in self?.receive(m, name: name) }
        client = c
        c.start()
    }

    private func clientChanged(_ s: GroupClient.Status, name: String) {
        switch s {
        case .searching, .connecting:
            state = .connecting(name)
        case .connected:
            flush()
        case let .reconnecting(why):
            state = .reconnecting(why)
        case let .stopped(why):
            if why == "Left" { return }
            state = .failed(why)
            let waiting = items.filter { !$0.isDone }.map(\.id)
            fail(waiting, why)
            queue.removeAll()
            client = nil
            clientTarget = nil
        }
    }

    private func receive(_ m: GroupMessage, name: String) {
        guard m.protocolVersion == GroupProtocol.version else {
            state = .failed("The Theater runs another version of the app (protocol \(m.protocolVersion)). Update both.")
            return
        }
        switch m.body {
        case let .receipt(r):
            if let i = items.firstIndex(where: { $0.id == r.id }) {
                items[i].receipt = r
                if items[i].progress != nil { items[i].progress = 1 }
            } else {
                state = .connected(name)   // the hello's receipt
                flush()
            }
            scheduleIdleStop()
        case let .refused(why):
            state = .failed(why)
        default:
            break
        }
    }

    /// Sends what's queued, one payload at a time (a file's chunks are paced so the link keeps up).
    private func flush() {
        guard !sending, let c = client, c.status == .connected, !queue.isEmpty else { return }
        sending = true
        Task { @MainActor in
            while let c = self.client, c.status == .connected, !self.queue.isEmpty {
                let p = self.queue.removeFirst()
                await self.deliver(p, over: c)
            }
            self.sending = false
            self.scheduleIdleStop()
        }
    }

    private func deliver(_ p: Payload, over c: GroupClient) async {
        switch p {
        case let .note(n):
            c.send(.fieldNote(n))
        case let .field(f):
            c.send(.fieldSubmission(f))
        case let .file(url, kind, group, courseID, id):
            guard let data = try? Data(contentsOf: url) else { return fail([id], "Couldn't read \(url.lastPathComponent).") }
            guard data.count <= FileOffer.maxBytes else { return fail([id], "Too big to send (over 50 MB).") }
            let offer = FileOffer(id: id, kind: kind, group: group, name: url.lastPathComponent, size: data.count,
                                  sha256: data.sha256Hex, courseID: courseID)
            c.send(.fileOffer(offer))
            for i in 0..<offer.chunkCount {
                guard c.status == .connected, client === c else { return fail([id], "The link dropped mid-file. Send it again.") }
                let start = i * FileOffer.chunkBytes
                let chunk = data.subdata(in: start..<min(data.count, start + FileOffer.chunkBytes))
                c.send(.fileChunk(FileChunk(file: id, index: i, data: chunk)))
                setProgress(id, Double(i + 1) / Double(offer.chunkCount))
                try? await Task.sleep(nanoseconds: 15_000_000)
            }
            c.send(.fileDone(id))
        }
    }

    private func setProgress(_ id: UUID, _ p: Double) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].progress = p }
    }

    private func fail(_ ids: [UUID], _ why: String) {
        for id in ids {
            if let i = items.firstIndex(where: { $0.id == id }), !items[i].isDone { items[i].failed = why }
        }
    }

    /// Lets the link go once nothing is queued or waiting for a receipt.
    private func scheduleIdleStop() {
        idleStop?.cancel()
        guard queue.isEmpty, !sending, !items.contains(where: { !$0.isDone }) else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.queue.isEmpty, !self.items.contains(where: { !$0.isDone }) else { return }
            self.disconnect()
        }
        idleStop = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleAfter, execute: w)
    }

    // MARK: Describing

    private static func describe(_ p: Payload) -> (UUID, String, Double?) {
        switch p {
        case let .note(n): return (n.id, "Note: " + (n.text.isEmpty ? "photo" : String(n.text.prefix(40))), nil)
        case let .field(f): return (f.id, "Field: \(f.course.name)", nil)
        case let .file(url, _, _, _, id): return (id, url.lastPathComponent, 0)
        }
    }
}
