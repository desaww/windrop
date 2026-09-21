import Foundation

struct VerlaufEintrag: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var groesse: Int
    var zeit: Date
    var erfolg: Bool
    var grund: String
}

/// Merkt sich, was verschickt wurde. Liegt als lesbare JSON-Datei in
/// ~/WinDrop/verlauf.json, damit man auch ohne die App nachsehen kann.
final class Verlauf: ObservableObject {

    private static let hoechstzahl = 100

    @Published private(set) var eintraege: [VerlaufEintrag] = []

    private var datei: URL { Ablage.basis.appendingPathComponent("verlauf.json") }

    init() {
        laden()
    }

    func hinzufuegen(name: String, groesse: Int, erfolg: Bool, grund: String) {
        let eintrag = VerlaufEintrag(id: Zufall.kennung(8), name: name, groesse: groesse,
                                     zeit: Date(), erfolg: erfolg, grund: grund)
        eintraege.insert(eintrag, at: 0)
        if eintraege.count > Self.hoechstzahl {
            eintraege.removeLast(eintraege.count - Self.hoechstzahl)
        }
        sichern()
    }

    func leeren() {
        eintraege = []
        sichern()
    }

    private func laden() {
        guard let daten = try? Data(contentsOf: datei) else { return }
        let dekoder = JSONDecoder()
        dekoder.dateDecodingStrategy = .iso8601
        eintraege = (try? dekoder.decode([VerlaufEintrag].self, from: daten)) ?? []
    }

    private func sichern() {
        let kodierer = JSONEncoder()
        kodierer.dateEncodingStrategy = .iso8601
        kodierer.outputFormatting = [.prettyPrinted]
        guard let daten = try? kodierer.encode(eintraege) else { return }
        Ablage.ordnerAnlegen()
        try? daten.write(to: datei, options: .atomic)
    }
}
