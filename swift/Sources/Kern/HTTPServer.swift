import Foundation
import Network
import CryptoKit

struct HTTPAnfrage {
    let methode: String
    let pfad: String
    let abfrage: [String: String]
    let kopfzeilen: [String: String]

    var code: String? { abfrage["t"] }
}

/// Mini-HTTP-Server auf Basis von Network.framework.
/// Kann genau das, was WinDrop braucht: Seite ausliefern, Dateien streamen,
/// WebSocket sprechen und Uploads der Teilen-Erweiterung annehmen.
final class HTTPServer {

    enum Startfehler: Error, LocalizedError {
        case portBelegt(UInt16)

        var errorDescription: String? {
            switch self {
            case .portBelegt(let p):
                return "Port \(p) ist belegt. Läuft WinDrop schon, "
                     + "oder noch die Python-Fassung?"
            }
        }
    }

    private var lauscher: NWListener?
    private let queue = DispatchQueue(label: "de.lennard.windrop.server")
    private let schlange: Warteschlange
    private let port: UInt16

    /// Haelt die offenen Sitzungen fest. Ohne diese Liste wuerden die
    /// Verbindungsobjekte sofort wieder freigegeben, weil sie sich selbst
    /// nur schwach in den Rueckrufen von NWConnection halten.
    private var sitzungen: [ObjectIdentifier: Sitzung] = [:]

    var beiMeldung: ((String) -> Void)?
    var beiStatus: ((Bool) -> Void)?

    init(schlange: Warteschlange, port: UInt16 = WinDropInfo.port) {
        self.schlange = schlange
        self.port = port
    }

    func starten() throws {
        // Keepalive: Nach Standby oder WLAN-Wechsel bleiben sonst tote
        // Verbindungen minutenlang stehen und die App meint, der
        // Windows-Laptop sei noch da.
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        tcp.keepaliveCount = 3
        tcp.keepaliveInterval = 5

        let parameter = NWParameters(tls: nil, tcp: tcp)
        parameter.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw Startfehler.portBelegt(port)
        }

        let l: NWListener
        do {
            l = try NWListener(using: parameter, on: nwPort)
        } catch {
            throw Startfehler.portBelegt(port)
        }

        l.newConnectionHandler = { [weak self] verbindung in
            guard let self else { return }
            let sitzung = Sitzung(verbindung: verbindung, server: self,
                                  schlange: self.schlange, queue: self.queue)
            self.merken(sitzung)
            sitzung.starten()
        }
        l.stateUpdateHandler = { [weak self] zustand in
            switch zustand {
            case .ready:
                self?.beiStatus?(true)
            case .failed, .cancelled:
                self?.beiStatus?(false)
            default:
                break
            }
        }
        l.start(queue: queue)
        lauscher = l
    }

    func anhalten() {
        lauscher?.cancel()
        lauscher = nil
        queue.async { self.sitzungen.removeAll() }
        beiStatus?(false)
    }

    fileprivate func merken(_ s: Sitzung) {
        queue.async { self.sitzungen[ObjectIdentifier(s)] = s }
    }

    fileprivate func vergessen(_ s: Sitzung) {
        queue.async { self.sitzungen.removeValue(forKey: ObjectIdentifier(s)) }
    }

    fileprivate func melden(_ text: String) {
        let zeile = Format.uhrzeit() + " " + text
        DispatchQueue.main.async { self.beiMeldung?(zeile) }
    }
}

// MARK: - Eine Verbindung

final class Sitzung {

    private enum Modus {
        case http
        case koerper(ziel: FileHandle, url: URL, name: String, offen: Int)
        case websocket
        case dauerstrom          // Ereignisstrom, hier kommt nichts mehr zurueck
    }

    private let verbindung: NWConnection
    private weak var server: HTTPServer?
    private let schlange: Warteschlange
    private let queue: DispatchQueue

    private var puffer = Data()
    private var modus: Modus = .http
    private var empfaenger: Empfaenger?
    private var beendet = false

    // Zustand der laufenden Dateiuebertragung
    private var leser: FileHandle?
    private var laufenderTransfer: Transfer?
    private var gesendet = 0
    private var letzteMeldung = Date.distantPast

    init(verbindung: NWConnection, server: HTTPServer,
         schlange: Warteschlange, queue: DispatchQueue) {
        self.verbindung = verbindung
        self.server = server
        self.schlange = schlange
        self.queue = queue
    }

    private var gegenstelle: String {
        if case .hostPort(let host, _) = verbindung.endpoint {
            switch host {
            case .ipv4(let a): return "\(a)"
            case .ipv6(let a): return "\(a)"
            case .name(let n, _): return n
            @unknown default: return "?"
            }
        }
        return "?"
    }

    private var istLokal: Bool {
        let a = gegenstelle
        return a.hasPrefix("127.") || a.hasPrefix("::1") || a == "localhost"
    }

    func starten() {
        verbindung.stateUpdateHandler = { [weak self] zustand in
            switch zustand {
            case .failed, .cancelled:
                self?.aufraeumen()
            default:
                break
            }
        }
        verbindung.start(queue: queue)
        lesen()
    }

    private func lesen() {
        verbindung.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] daten, _, fertig, fehler in
            guard let self else { return }
            if let daten, !daten.isEmpty {
                self.puffer.append(daten)
                self.verarbeiten()
            }
            if fertig || fehler != nil {
                self.aufraeumen()
                return
            }
            if !self.beendet { self.lesen() }
        }
    }

    private func aufraeumen() {
        guard !beendet else { return }
        beendet = true
        try? leser?.close()
        leser = nil
        if let t = laufenderTransfer, t.status == .laeuft {
            schlange.abgebrochen(t)
            laufenderTransfer = nil
        }
        if let e = empfaenger {
            schlange.abmelden(e)
            empfaenger = nil
        }
        verbindung.cancel()
        server?.vergessen(self)
    }

    // MARK: Verarbeiten

    private func verarbeiten() {
        switch modus {
        case .http:       httpVerarbeiten()
        case .koerper:    koerperVerarbeiten()
        case .websocket:  websocketVerarbeiten()
        case .dauerstrom: puffer.removeAll()
        }
    }

    private func httpVerarbeiten() {
        guard let ende = puffer.range(of: Data("\r\n\r\n".utf8)) else { return }
        let kopfDaten = puffer.subdata(in: puffer.startIndex..<ende.lowerBound)
        puffer.removeSubrange(puffer.startIndex..<ende.upperBound)

        guard let kopf = String(data: kopfDaten, encoding: .utf8) else {
            antwort(400, text: "Kopfzeilen nicht lesbar")
            return
        }
        let zeilen = kopf.components(separatedBy: "\r\n")
        let teile = zeilen[0].components(separatedBy: " ")
        guard teile.count >= 2 else {
            antwort(400, text: "Fehlerhafte Anfrage")
            return
        }

        var kopfzeilen: [String: String] = [:]
        for zeile in zeilen.dropFirst() {
            guard let doppelpunkt = zeile.firstIndex(of: ":") else { continue }
            let name = String(zeile[zeile.startIndex..<doppelpunkt]).lowercased()
            let wert = String(zeile[zeile.index(after: doppelpunkt)...])
                .trimmingCharacters(in: .whitespaces)
            kopfzeilen[name] = wert
        }

        let zerlegt = teile[1].components(separatedBy: "?")
        var abfrage: [String: String] = [:]
        if zerlegt.count > 1 {
            for paar in zerlegt[1].components(separatedBy: "&") {
                let kv = paar.components(separatedBy: "=")
                if kv.count == 2 {
                    abfrage[kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
                }
            }
        }

        weiterleiten(HTTPAnfrage(methode: teile[0], pfad: zerlegt[0],
                                 abfrage: abfrage, kopfzeilen: kopfzeilen))
    }

    // MARK: Routen

    private func weiterleiten(_ a: HTTPAnfrage) {
        if a.methode == "GET", a.pfad.hasPrefix("/f/") {
            guard Zugangscode.stimmt(a.code) else { antwort(403, text: "forbidden"); return }
            dateiSenden(kennung: String(a.pfad.dropFirst(3)))
            return
        }

        switch (a.methode, a.pfad) {

        case ("GET", "/favicon.ico"):
            antwort(204, text: "")

        case ("GET", "/"), ("GET", "/r"), ("GET", "/index.html"):
            guard Zugangscode.stimmt(a.code) else {
                antwort(403, text: "WinDrop: ungültiger oder fehlender Zugangscode.")
                return
            }
            let seite = EmpfangsSeite.html
                .replacingOccurrences(of: "__TOKEN__", with: Zugangscode.aktuell)
            antwort(200, text: seite, typ: "text/html; charset=utf-8")

        case ("GET", "/ws"):
            guard Zugangscode.stimmt(a.code) else { antwort(403, text: "forbidden"); return }
            websocketHandschlag(a)

        case ("GET", "/events"):
            guard Zugangscode.stimmt(a.code) else { antwort(403, text: "forbidden"); return }
            ereignisstromStarten()

        case ("GET", "/api/status"):
            guard istLokal, Zugangscode.stimmt(a.code) else {
                antwort(403, text: "forbidden"); return
            }
            let daten: [String: Any] = [
                "empfaenger": schlange.empfaengerNamen(),
                "transfers": schlange.alleAnsichten().map {
                    ["id": $0.id, "name": $0.name, "groesse": $0.groesse,
                     "groesse_text": Format.groesse($0.groesse),
                     "gesendet": $0.gesendet, "status": $0.status, "grund": $0.grund]
                },
            ]
            antwort(200, text: JSON.text(daten) ?? "{}", typ: "application/json; charset=utf-8")

        case ("POST", "/api/upload"):
            // Nur von diesem Mac. Hier laedt die Teilen-Erweiterung die Bytes hoch.
            guard istLokal else { antwort(403, text: "forbidden"); return }
            uploadBeginnen(a)

        default:
            antwort(404, text: "not found")
        }
    }

    // MARK: Antworten

    private func antwort(_ status: Int, text: String,
                         typ: String = "text/plain; charset=utf-8") {
        let koerper = Data(text.utf8)
        var kopf = "HTTP/1.1 \(status) \(Self.statustext(status))\r\n"
        kopf += "Content-Type: \(typ)\r\n"
        kopf += "Content-Length: \(koerper.count)\r\n"
        kopf += "Cache-Control: no-store\r\n\r\n"
        senden(Data(kopf.utf8) + koerper)
    }

    private func senden(_ daten: Data, danach: (() -> Void)? = nil) {
        verbindung.send(content: daten, completion: .contentProcessed { [weak self] fehler in
            guard let self else { return }
            if fehler != nil {
                self.aufraeumen()
                return
            }
            danach?()
        })
    }

    private static func statustext(_ status: Int) -> String {
        switch status {
        case 101: return "Switching Protocols"
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 410: return "Gone"
        case 500: return "Internal Server Error"
        default:  return "OK"
        }
    }

    // MARK: Datei ausliefern

    private func dateiSenden(kennung: String) {
        guard let t = schlange.transfer(id: kennung) else {
            antwort(404, text: "Unbekannte Datei."); return
        }
        if t.status == .fertig {
            antwort(410, text: "Bereits übertragen."); return
        }
        guard let handle = try? FileHandle(forReadingFrom: t.pfad) else {
            antwort(404, text: "Datei nicht mehr vorhanden."); return
        }

        leser = handle
        laufenderTransfer = t
        gesendet = 0
        letzteMeldung = .distantPast
        schlange.beginnt(t)

        let ascii = Dateiname.asciiErsatz(t.name)
        let erlaubt = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let kodiert = t.name.addingPercentEncoding(withAllowedCharacters: erlaubt) ?? ascii

        var kopf = "HTTP/1.1 200 OK\r\n"
        kopf += "Content-Type: application/octet-stream\r\n"
        kopf += "Content-Length: \(t.groesse)\r\n"
        kopf += "Content-Disposition: attachment; filename=\"\(ascii)\"; "
        kopf += "filename*=UTF-8''\(kodiert)\r\n"
        kopf += "Cache-Control: no-store\r\n\r\n"

        senden(Data(kopf.utf8)) { [weak self] in self?.naechsterBrocken() }
    }

    /// Schickt die Datei Stueck fuer Stueck. Der Rueckruf von NWConnection
    /// kommt erst, wenn der Brocken wirklich raus ist. Dadurch passt sich das
    /// Tempo von allein an die Leitung an.
    private func naechsterBrocken() {
        guard !beendet, let handle = leser, let t = laufenderTransfer else { return }

        let brocken = (try? handle.read(upToCount: 128 * 1024)) ?? nil
        guard let brocken, !brocken.isEmpty else {
            try? handle.close()
            leser = nil
            laufenderTransfer = nil
            schlange.fortschritt(t, gesendet: t.groesse)
            schlange.abgeschlossen(t)
            return
        }

        verbindung.send(content: brocken, completion: .contentProcessed { [weak self] fehler in
            guard let self else { return }
            if fehler != nil {
                try? handle.close()
                self.leser = nil
                self.laufenderTransfer = nil
                self.schlange.abgebrochen(t)
                self.aufraeumen()
                return
            }
            self.gesendet += brocken.count
            if Date().timeIntervalSince(self.letzteMeldung) >= 0.15 {
                self.letzteMeldung = Date()
                self.schlange.fortschritt(t, gesendet: self.gesendet)
            }
            self.naechsterBrocken()
        })
    }

    // MARK: Upload der Teilen-Erweiterung

    private func uploadBeginnen(_ a: HTTPAnfrage) {
        guard let laengeText = a.kopfzeilen["content-length"],
              let laenge = Int(laengeText), laenge > 0 else {
            antwort(400, text: "Content-Length fehlt oder ist null"); return
        }
        let name = Dateiname.saeubern(a.abfrage["name"] ?? "datei")

        Ablage.ordnerAnlegen()
        let ordner = Ablage.zwischenlager.appendingPathComponent(Zufall.kennung(6))
        try? FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        let ziel = ordner.appendingPathComponent(name)
        _ = FileManager.default.createFile(atPath: ziel.path, contents: nil)

        guard let schreiber = try? FileHandle(forWritingTo: ziel) else {
            antwort(500, text: "Zwischenlager nicht beschreibbar"); return
        }
        // Der Koerper geht direkt auf die Platte, nicht in den Arbeitsspeicher.
        // Sonst waere eine 2-GB-Datei ein Problem.
        modus = .koerper(ziel: schreiber, url: ziel, name: name, offen: laenge)
        koerperVerarbeiten()
    }

    private func koerperVerarbeiten() {
        guard case .koerper(let ziel, let url, let name, let offen) = modus else { return }

        var restlich = offen
        if !puffer.isEmpty, restlich > 0 {
            let menge = min(restlich, puffer.count)
            try? ziel.write(contentsOf: puffer.prefix(menge))
            puffer.removeFirst(menge)
            restlich -= menge
        }

        if restlich > 0 {
            modus = .koerper(ziel: ziel, url: url, name: name, offen: restlich)
            return
        }

        try? ziel.close()
        modus = .http
        if let t = schlange.einreihen(pfad: url, archivieren: true) {
            antwort(200, text: JSON.text(["ok": true, "id": t.id, "name": name]) ?? "{}",
                    typ: "application/json; charset=utf-8")
        } else {
            antwort(500, text: "Konnte nicht eingereiht werden")
        }
    }

    // MARK: WebSocket

    private func websocketHandschlag(_ a: HTTPAnfrage) {
        guard let schluessel = a.kopfzeilen["sec-websocket-key"] else {
            antwort(400, text: "kein WebSocket-Handschlag"); return
        }
        let roh = Data((schluessel + WebSocketRahmen.handschlagGUID).utf8)
        let quittung = Data(Insecure.SHA1.hash(data: roh)).base64EncodedString()

        var kopf = "HTTP/1.1 101 Switching Protocols\r\n"
        kopf += "Upgrade: websocket\r\n"
        kopf += "Connection: Upgrade\r\n"
        kopf += "Sec-WebSocket-Accept: \(quittung)\r\n\r\n"

        modus = .websocket
        senden(Data(kopf.utf8)) { [weak self] in
            guard let self else { return }
            let e = Empfaenger(adresse: self.gegenstelle, art: "ws") { [weak self] text in
                self?.verbindung.send(content: WebSocketRahmen.kodieren(text: text),
                                      completion: .contentProcessed { _ in })
            }
            self.empfaenger = e
            self.schlange.anmelden(e)
            self.pingTaktStarten()
        }
    }

    private func pingTaktStarten() {
        queue.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, !self.beendet else { return }
            guard case .websocket = self.modus else { return }
            self.verbindung.send(content: WebSocketRahmen.kodieren(Data(), opcode: 0x9),
                                 completion: .contentProcessed { _ in })
            self.pingTaktStarten()
        }
    }

    private func websocketVerarbeiten() {
        while let rahmen = WebSocketRahmen.dekodieren(puffer) {
            puffer.removeFirst(rahmen.verbraucht)
            switch rahmen.opcode {
            case 0x8:
                aufraeumen()
                return
            case 0x9:
                verbindung.send(content: WebSocketRahmen.kodieren(rahmen.nutzlast, opcode: 0xA),
                                completion: .contentProcessed { _ in })
            default:
                break            // Textnachrichten braucht M2 noch nicht
            }
        }
    }

    // MARK: Ereignisstrom als Rueckfallebene

    private func ereignisstromStarten() {
        var kopf = "HTTP/1.1 200 OK\r\n"
        kopf += "Content-Type: text/event-stream; charset=utf-8\r\n"
        kopf += "Cache-Control: no-cache, no-transform\r\n"
        kopf += "Connection: keep-alive\r\n"
        kopf += "X-Accel-Buffering: no\r\n\r\n"

        modus = .dauerstrom
        senden(Data(kopf.utf8)) { [weak self] in
            guard let self else { return }
            let e = Empfaenger(adresse: self.gegenstelle, art: "sse") { [weak self] text in
                let zeile = "data: " + text + "\n\n"
                self?.verbindung.send(content: Data(zeile.utf8),
                                      completion: .contentProcessed { _ in })
            }
            self.empfaenger = e
            self.schlange.anmelden(e)
        }
    }
}
