import Foundation

struct HistoryEntry: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var size: Int
    var date: Date
    var success: Bool
    var reason: String
}

/// Keeps track of what was sent. Stored as readable JSON in
/// ~/WinDrop/history.json so it can be inspected without the app.
final class History: ObservableObject {

    private static let limit = 100

    @Published private(set) var entries: [HistoryEntry] = []

    private var file: URL { Storage.base.appendingPathComponent("history.json") }

    init() {
        load()
    }

    func add(name: String, size: Int, success: Bool, reason: String) {
        let entry = HistoryEntry(id: RandomID.make(8), name: name, size: size,
                                 date: Date(), success: success, reason: reason)
        entries.insert(entry, at: 0)
        if entries.count > Self.limit {
            entries.removeLast(entries.count - Self.limit)
        }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(entries) else { return }
        Storage.createFolders()
        try? data.write(to: file, options: .atomic)
    }
}
