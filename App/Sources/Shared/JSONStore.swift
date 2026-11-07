import Foundation

/// A small list of records saved as JSON in the app's Documents folder, newest first.
final class JSONStore<Item: Codable & Identifiable>: ObservableObject {
    @Published private(set) var items: [Item] = []
    private let fileURL: URL

    init(fileName: String) {
        fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(fileName)
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved
        }
    }

    func add(_ item: Item) { items.insert(item, at: 0); save() }
    func delete(at offsets: IndexSet) { items.remove(atOffsets: offsets); save() }

    private func save() { try? JSONEncoder().encode(items).write(to: fileURL, options: .atomic) }

    /// Writes text to a temporary file for sharing.
    func exportFile(named name: String, contents: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
