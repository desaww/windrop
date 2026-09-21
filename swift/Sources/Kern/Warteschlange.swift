import Foundation

enum TransferStatus: String {
    case wartend, angeboten, laeuft, fertig, fehler
}

final class Transfer {
    let id: String
    var pfad: URL
    let name: String
    let groesse: Int
    let archivieren: Bool

    var status: TransferStatus = .wartend
    var gesendet: Int = 0
    var versuche: Int = 0
    var angebotenUm: Date = .distantPast
    var beendet: Date?
    var grund: String = ""

    init(pfad: URL, groesse: Int, archivieren: Bool) {
        self.id = Zufall.kennung(9)
        self.pfad = pfad
        self.name = pfad.lastPathComponent
        self.groesse = groesse
        self.archivieren = archivieren
    }
}

/// Momentaufnahme fuer die Oberflaeche. Bewusst ein Wert, damit SwiftUI
/// nicht auf veraenderliche Objekte schaut.
struct TransferAnsicht: Identifiable, Equatable {
    let id: String
    let name: String
    let groesse: Int
    let gesendet: Int
    let status: String
    let grund: String

    var anteil: Double { groesse > 0 ? Double(gesendet) / Double(groesse) : 0 }
}

final class Empfaenger {
    let id = UUID()
    let adresse: String
    let art: String            // "ws" oder "sse"
    let schreiben: (String) -> Void
    var lebt = true

    init(adresse: String, art: String, schreiben: @escaping (String) -> Void) {
        self.adresse = adresse
        self.art = art
        self.schreiben = schreiben
    }

    func sende(_ nachricht: [String: Any]) {
        guard lebt, let text = JSON.text(nachricht) else { return }
        schreiben(text)
    }
}

/// Verwaltet Warteschlange und verbundene Empfaenger.
///
/// Gesperrt wird mit einer wiedereintrittsfaehigen Sperre. Eine serielle
/// DispatchQueue waere hier gefaehrlich: Sobald eine Methode innerhalb der
/// Sperre eine andere gesperrte Methode aufruft, verklemmt sich das Programm.
final class Warteschlange {

    static let angebotTimeout: TimeInterval = 30
    static let maxVersuche = 3
    static let aufraeumenNach: TimeInterval = 3600

    private let sperre = NSRecursiveLock()
    private var transfers: [Transfer] = []
    private var empfaenger: [Empfaenger] = []
    private var takt: DispatchSourceTimer?
    private let taktQueue = DispatchQueue(label: "de.lennard.windrop.planer")

    /// Wird nach jeder Aenderung aufgerufen, damit die Oberflaeche sich auffrischt.
    var beiAenderung: (([TransferAnsicht], [String]) -> Void)?
    var beiMeldung: ((String) -> Void)?
    /// Name, Groesse, Erfolg, Grund - fuer Verlauf und Mitteilungen.
    var beiAbschluss: ((String, Int, Bool, String) -> Void)?

    private func imLock<T>(_ block: () -> T) -> T {
        sperre.lock()
        defer { sperre.unlock() }
        return block()
    }

    // MARK: Start

    func starten() {
        let t = DispatchSource.makeTimerSource(queue: taktQueue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.planen() }
        t.resume()
        takt = t
    }

    // MARK: Empfaenger

    func anmelden(_ e: Empfaenger) {
        imLock { empfaenger.append(e) }
        melden("Empfänger verbunden: \(e.adresse) (\(e.art.uppercased()))")
        e.sende(["typ": "willkommen",
                 "geraet": Host.current().localizedName ?? "Mac",
                 "version": WinDropInfo.version])
        for t in imLock({ transfers.filter { $0.status == .angeboten } }) {
            e.sende(angebot(t))
        }
        aenderungMelden()
    }

    func abmelden(_ e: Empfaenger) {
        e.lebt = false
        imLock { empfaenger.removeAll { $0.id == e.id } }
        melden("Empfänger getrennt: \(e.adresse)")
        aenderungMelden()
    }

    private func rundruf(_ nachricht: [String: Any]) {
        for e in imLock({ empfaenger }) { e.sende(nachricht) }
    }

    // MARK: Einreihen

    @discardableResult
    func einreihen(pfad: URL, archivieren: Bool = false) -> Transfer? {
        guard let werte = try? FileManager.default.attributesOfItem(atPath: pfad.path),
              let groesse = werte[.size] as? Int else { return nil }
        let t = Transfer(pfad: pfad, groesse: groesse, archivieren: archivieren)
        imLock { transfers.append(t) }
        melden("In der Warteschlange: \(t.name) (\(Format.groesse(groesse)))")
        aenderungMelden()
        return t
    }

    func transfer(id: String) -> Transfer? {
        imLock { transfers.first { $0.id == id } }
    }

    func alleAnsichten() -> [TransferAnsicht] {
        imLock { transfers.map(ansicht) }
    }

    func empfaengerNamen() -> [String] {
        imLock { empfaenger.map { $0.adresse } }
    }

    func istEmpfaengerDa() -> Bool {
        imLock { !empfaenger.isEmpty }
    }

    private func ansicht(_ t: Transfer) -> TransferAnsicht {
        TransferAnsicht(id: t.id, name: t.name, groesse: t.groesse,
                        gesendet: t.gesendet, status: t.status.rawValue, grund: t.grund)
    }

    private func angebot(_ t: Transfer) -> [String: Any] {
        [
            "typ": "datei",
            "id": t.id,
            "name": t.name,
            "groesse": t.groesse,
            "groesse_text": Format.groesse(t.groesse),
            "url": "/f/\(t.id)?t=\(Zugangscode.aktuell)",
        ]
    }

    // MARK: Planer

    /// Laeuft im Takt und gibt immer nur eine Datei gleichzeitig frei.
    private func planen() {
        var zuMelden: [[String: Any]] = []

        imLock {
            var laufend = transfers.filter { $0.status == .angeboten || $0.status == .laeuft }

            for t in laufend where t.status == .angeboten {
                guard Date().timeIntervalSince(t.angebotenUm) > Self.angebotTimeout else { continue }
                if t.versuche >= Self.maxVersuche {
                    t.status = .fehler
                    t.grund = "Empfänger hat nicht reagiert"
                    t.beendet = Date()
                    melden("Aufgegeben: \(t.name) (keine Reaktion)")
                    zuMelden.append(["typ": "fehler", "id": t.id, "grund": t.grund])
                    abschlussMelden(t.name, t.groesse, false, t.grund)
                } else {
                    t.status = .wartend
                    melden("Erneuter Versuch: \(t.name)")
                }
                laufend.removeAll { $0.id == t.id }
            }

            if laufend.isEmpty, !empfaenger.isEmpty,
               let naechster = transfers.first(where: { $0.status == .wartend }) {
                naechster.status = .angeboten
                naechster.versuche += 1
                naechster.angebotenUm = Date()
                naechster.gesendet = 0
                zuMelden.append(angebot(naechster))
                melden("Angeboten: \(naechster.name) (Versuch \(naechster.versuche))")
            }

            transfers.removeAll { t in
                guard let ende = t.beendet else { return false }
                return (t.status == .fertig || t.status == .fehler)
                    && Date().timeIntervalSince(ende) > Self.aufraeumenNach
            }
        }

        for m in zuMelden { rundruf(m) }
        if !zuMelden.isEmpty { aenderungMelden() }
    }

    // MARK: Zustandsuebergaenge, vom Server aufgerufen

    func beginnt(_ t: Transfer) {
        imLock {
            t.status = .laeuft
            t.gesendet = 0
        }
        aenderungMelden()
    }

    func fortschritt(_ t: Transfer, gesendet: Int) {
        imLock { t.gesendet = gesendet }
        rundruf(["typ": "fortschritt", "id": t.id, "gesendet": gesendet])
        aenderungMelden()
    }

    func abgeschlossen(_ t: Transfer) {
        let dauer = max(Date().timeIntervalSince(t.angebotenUm), 0.001)
        imLock {
            t.status = .fertig
            t.gesendet = t.groesse
            t.beendet = Date()
        }
        melden("Angekommen: \(t.name) (\(Format.groesse(t.groesse)) in "
               + String(format: "%.1f", dauer) + " s, "
               + Format.groesse(Int(Double(t.groesse) / dauer)) + "/s)")
        rundruf(["typ": "fertig", "id": t.id])
        if t.archivieren { Ablage.aufraeumen(t) }
        abschlussMelden(t.name, t.groesse, true, "")
        aenderungMelden()
    }

    func abgebrochen(_ t: Transfer) {
        let bisher = t.gesendet
        imLock { t.status = .wartend }
        melden("Abbruch bei \(t.name) nach \(Format.groesse(bisher))"
               + " – kommt zurück in die Schlange")
        aenderungMelden()
    }

    // MARK: Eingriffe aus der Oberflaeche

    /// Stellt eine gescheiterte Uebertragung zurueck in die Schlange.
    func erneutVersuchen(id: String) {
        var name = ""
        imLock {
            guard let t = transfers.first(where: { $0.id == id }), t.status == .fehler else { return }
            t.status = .wartend
            t.versuche = 0
            t.gesendet = 0
            t.grund = ""
            t.beendet = nil
            name = t.name
        }
        guard !name.isEmpty else { return }
        melden("Neuer Anlauf: \(name)")
        aenderungMelden()
    }

    /// Raeumt fertige und gescheiterte Eintraege aus der Anzeige.
    func listeLeeren() {
        imLock {
            transfers.removeAll { $0.status == .fertig || $0.status == .fehler }
        }
        aenderungMelden()
    }

    // MARK: Hilfen

    private func abschlussMelden(_ name: String, _ groesse: Int, _ erfolg: Bool, _ grund: String) {
        DispatchQueue.main.async { self.beiAbschluss?(name, groesse, erfolg, grund) }
    }

    private func melden(_ text: String) {
        let zeile = Format.uhrzeit() + " " + text
        DispatchQueue.main.async { self.beiMeldung?(zeile) }
    }

    private func aenderungMelden() {
        let ansichten = imLock { transfers.map(ansicht) }
        let namen = imLock { empfaenger.map { $0.adresse } }
        DispatchQueue.main.async { self.beiAenderung?(ansichten, namen) }
    }
}
