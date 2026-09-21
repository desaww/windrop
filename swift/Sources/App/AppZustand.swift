import Foundation
import AppKit
import Network

/// Haelt den Zustand fuer die Oberflaeche und startet den Server.
///
/// Bewusst ohne @MainActor: Die Rueckrufe kommen aus Server-Threads. Sie
/// werden hier von Hand auf den Hauptthread gelegt. Das ist unter Swift 5
/// eindeutig und erspart Aktor-Klimmzuege.
final class AppZustand: ObservableObject {

    @Published var laeuft = false
    @Published var startfehler: String?
    @Published var empfaengerNamen: [String] = []
    @Published var transfers: [TransferAnsicht] = []
    @Published var protokoll: [String] = []
    @Published var packtGerade = false

    let einstellungen = Einstellungen.geteilt
    let verlauf = Verlauf()

    private let schlange = Warteschlange()
    private var server: HTTPServer?
    private var waechter: OutboxWaechter?
    private var netzwache: NWPathMonitor?
    private var aufwachBeobachter: NSObjectProtocol?
    private var letzteAdresse = ""
    private let packQueue = DispatchQueue(label: "de.lennard.windrop.packen")

    var verbunden: Bool { !empfaengerNamen.isEmpty }

    var statustext: String {
        if startfehler != nil { return "Nicht gestartet" }
        if empfaengerNamen.isEmpty {
            return laeuft ? "Warte auf Windows-Tab" : "Server startet"
        }
        return empfaengerNamen.count == 1
            ? "Verbunden mit \(empfaengerNamen[0])"
            : "\(empfaengerNamen.count) Empfänger verbunden"
    }

    var adresseName: String {
        "http://\(Netz.bonjourName):\(WinDropInfo.port)/?t=\(Zugangscode.aktuell)"
    }

    var adresseIP: String {
        "http://\(Netz.lokaleAdresse):\(WinDropInfo.port)/?t=\(Zugangscode.aktuell)"
    }

    init() {
        Ablage.ordnerAnlegen()

        schlange.beiAenderung = { [weak self] ansichten, namen in
            DispatchQueue.main.async {
                guard let self else { return }
                self.transfers = Array(ansichten.reversed())
                self.empfaengerNamen = namen
            }
        }
        schlange.beiMeldung = { [weak self] zeile in
            DispatchQueue.main.async { self?.notieren(zeile) }
        }
        schlange.beiAbschluss = { [weak self] name, groesse, erfolg, grund in
            DispatchQueue.main.async {
                self?.abschlussMerken(name: name, groesse: groesse, erfolg: erfolg, grund: grund)
            }
        }
        schlange.starten()

        Ablage.zwischenlagerAufraeumen { zeile in
            print(zeile)
        }

        serverStarten()

        let w = OutboxWaechter(schlange: schlange)
        w.starten()
        waechter = w

        Mitteilung.erlaubnisHolen()
        aufwachenBeobachten()
        netzBeobachten()
    }

    // MARK: Server

    private func serverStarten() {
        let s = HTTPServer(schlange: schlange)
        s.beiMeldung = { [weak self] zeile in
            DispatchQueue.main.async { self?.notieren(zeile) }
        }
        s.beiStatus = { [weak self] bereit in
            DispatchQueue.main.async { self?.laeuft = bereit }
        }
        do {
            try s.starten()
            server = s
            startfehler = nil
            notieren(Format.uhrzeit() + " WinDrop \(WinDropInfo.version) bereit")
        } catch {
            startfehler = error.localizedDescription
            notieren(Format.uhrzeit() + " Start fehlgeschlagen: " + error.localizedDescription)
        }
    }

    func serverNeuStarten() {
        server?.anhalten()
        server = nil
        // Kurz warten, bis das System den Port wieder freigibt.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.serverStarten()
        }
    }

    /// Nach dem Aufwachen sind alte Verbindungen tot. Ein Neustart des
    /// Servers ist der zuverlaessigste Weg zurueck in einen sauberen Zustand;
    /// die Empfangsseite im Browser verbindet sich von allein neu.
    private func aufwachenBeobachten() {
        aufwachBeobachter = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.notieren(Format.uhrzeit() + " Mac ist aufgewacht – Server startet neu")
            self.serverNeuStarten()
        }
    }

    /// Wechselt der Mac das Netz, aendert sich die IP-Adresse. Dann muss der
    /// Lauscher neu aufgesetzt werden, sonst haengt er an der alten Schnittstelle.
    private func netzBeobachten() {
        letzteAdresse = Netz.lokaleAdresse
        let wache = NWPathMonitor()
        wache.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let jetzt = Netz.lokaleAdresse
                guard jetzt != self.letzteAdresse else { return }
                self.letzteAdresse = jetzt
                self.notieren(Format.uhrzeit() + " Netzwechsel erkannt (\(jetzt)) – Server startet neu")
                self.serverNeuStarten()
            }
        }
        wache.start(queue: DispatchQueue(label: "de.lennard.windrop.netz"))
        netzwache = wache
    }

    // MARK: Senden

    func senden(_ urls: [URL]) {
        let fm = FileManager.default
        var gefunden: [(url: URL, istOrdner: Bool)] = []

        for url in urls {
            var istOrdner: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &istOrdner) else {
                notieren(Format.uhrzeit() + " Nicht gefunden: " + url.lastPathComponent)
                continue
            }
            gefunden.append((url, istOrdner.boolValue))
        }
        guard !gefunden.isEmpty else { return }

        // Mehrere Objekte auf einmal: ein Archiv statt vieler Downloads.
        if einstellungen.alsZipBuendeln, gefunden.count > 1 {
            packenUndSenden(gefunden.map { $0.url })
            return
        }

        for eintrag in gefunden {
            if eintrag.istOrdner {
                // Ordner gehen nur als Archiv, unabhaengig von der Einstellung.
                packenUndSenden([eintrag.url])
            } else {
                schlange.einreihen(pfad: eintrag.url, archivieren: false)
            }
        }
    }

    private func packenUndSenden(_ quellen: [URL]) {
        let beschreibung = quellen.count == 1
            ? quellen[0].lastPathComponent
            : "\(quellen.count) Objekte"
        packtGerade = true
        notieren(Format.uhrzeit() + " Packe \(beschreibung) als ZIP-Archiv …")

        packQueue.async { [weak self] in
            let ergebnis = Paket.schnueren(quellen)
            DispatchQueue.main.async {
                guard let self else { return }
                self.packtGerade = false
                guard let archiv = ergebnis else {
                    self.notieren(Format.uhrzeit() + " Packen fehlgeschlagen: " + beschreibung)
                    if self.einstellungen.mitteilungBeiFehler {
                        Mitteilung.zeigen(titel: "WinDrop",
                                          text: "Packen fehlgeschlagen: " + beschreibung)
                    }
                    return
                }
                self.schlange.einreihen(pfad: archiv, archivieren: true)
            }
        }
    }

    private func abschlussMerken(name: String, groesse: Int, erfolg: Bool, grund: String) {
        verlauf.hinzufuegen(name: name, groesse: groesse, erfolg: erfolg, grund: grund)
        if erfolg, einstellungen.mitteilungBeiErfolg {
            Mitteilung.zeigen(titel: "Angekommen", text: name)
        }
        if !erfolg, einstellungen.mitteilungBeiFehler {
            Mitteilung.zeigen(titel: "Nicht gesendet",
                              text: grund.isEmpty ? name : name + " – " + grund)
        }
    }

    // MARK: Weitere Aktionen aus der Oberflaeche

    func erneutVersuchen(_ id: String) {
        schlange.erneutVersuchen(id: id)
    }

    func listeLeeren() {
        schlange.listeLeeren()
    }

    func adresseKopieren() {
        inZwischenablage(adresseName, "Adresse")
    }

    func adresseIPKopieren() {
        inZwischenablage(adresseIP, "IP-Adresse")
    }

    private func inZwischenablage(_ text: String, _ was: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notieren(Format.uhrzeit() + " \(was) in die Zwischenablage gelegt")
    }

    func neuerZugangscode() {
        Zugangscode.neu()
        notieren(Format.uhrzeit()
                 + " Neuer Zugangscode – Adresse am Windows-Laptop neu öffnen")
        objectWillChange.send()
    }

    private func notieren(_ zeile: String) {
        protokoll.append(zeile)
        if protokoll.count > 200 { protokoll.removeFirst(protokoll.count - 200) }
    }

    func beenden() {
        server?.anhalten()
        NSApplication.shared.terminate(nil)
    }
}
