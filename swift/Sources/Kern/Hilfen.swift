import Foundation
import Security   // SecRandomCopyBytes
import Darwin    // getifaddrs

enum WinDropInfo {
    static let version = "0.4 (M3)"
    static let port: UInt16 = 8787
}

enum Zufall {
    /// URL-sichere Zufallskennung.
    static func kennung(_ bytes: Int) -> String {
        var rohdaten = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &rohdaten)
        return Data(rohdaten).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum Format {
    static func groesse(_ bytes: Int) -> String {
        var wert = Double(bytes)
        let einheiten = ["B", "KB", "MB", "GB"]
        var i = 0
        while wert >= 1024, i < einheiten.count - 1 {
            wert /= 1024
            i += 1
        }
        return i == 0 ? "\(bytes) B" : String(format: "%.1f %@", wert, einheiten[i])
    }

    static func uhrzeit() -> String {
        let f = DateFormatter()
        f.dateFormat = "[HH:mm:ss]"
        return f.string(from: Date())
    }
}

enum JSON {
    static func text(_ objekt: [String: Any]) -> String? {
        guard let daten = try? JSONSerialization.data(withJSONObject: objekt),
              let text = String(data: daten, encoding: .utf8) else { return nil }
        return text
    }

    static func woerterbuch(_ daten: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: daten) as? [String: Any]
    }
}

/// Ordner und Zugangscode liegen dort, wo sie auch die Python-Fassung erwartet.
/// So bleiben beide Versionen austauschbar.
enum Ablage {
    static var basis: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("WinDrop")
    }
    static var outbox: URL { basis.appendingPathComponent("Outbox") }
    static var zwischenlager: URL { basis.appendingPathComponent(".stage") }
    static var codeDatei: URL { basis.appendingPathComponent("token.txt") }

    static func ordnerAnlegen() {
        for ordner in [basis, outbox, zwischenlager] {
            try? FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        }
    }

    /// Freien Namen im Zielordner finden, damit nichts ueberschrieben wird.
    static func freierName(in ordner: URL, name: String) -> URL {
        let fm = FileManager.default
        var ziel = ordner.appendingPathComponent(name)
        let stamm = (name as NSString).deletingPathExtension
        let endung = (name as NSString).pathExtension
        var i = 1
        while fm.fileExists(atPath: ziel.path) {
            let neu = endung.isEmpty ? "\(stamm) (\(i))" : "\(stamm) (\(i)).\(endung)"
            ziel = ordner.appendingPathComponent(neu)
            i += 1
        }
        return ziel
    }

    /// Nach erfolgreicher Uebertragung aufraeumen.
    ///
    /// Gilt nur fuer Dateien, die WinDrop selbst ins Zwischenlager gelegt hat
    /// (Outbox und Teilen-Menue). Originale, die nur per Verweis gesendet
    /// wurden (Ziehen und Dateiauswahl), bleiben unangetastet.
    static func aufraeumen(_ t: Transfer) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            let fm = FileManager.default
            let quelle = t.pfad
            guard quelle.path.hasPrefix(zwischenlager.path) else { return }
            try? fm.removeItem(at: quelle)
            let ordner = quelle.deletingLastPathComponent()
            if ordner.path.hasPrefix(zwischenlager.path), ordner.path != zwischenlager.path {
                try? fm.removeItem(at: ordner)
            }
        }
    }

    /// Nach einem Neustart sind alte Angebote hinfaellig. Was noch im
    /// Zwischenlager liegt, wandert zurueck in die Outbox.
    static func zwischenlagerAufraeumen(melden: (String) -> Void) {
        let fm = FileManager.default
        guard let ordner = try? fm.contentsOfDirectory(at: zwischenlager,
                                                       includingPropertiesForKeys: nil) else { return }
        for unterordner in ordner {
            guard let dateien = try? fm.contentsOfDirectory(at: unterordner,
                                                            includingPropertiesForKeys: nil) else { continue }
            for datei in dateien {
                let ziel = freierName(in: outbox, name: datei.lastPathComponent)
                if (try? fm.moveItem(at: datei, to: ziel)) != nil {
                    melden("Wiederhergestellt in die Outbox: \(ziel.lastPathComponent)")
                }
            }
            try? fm.removeItem(at: unterordner)
        }
    }
}

enum Zugangscode {
    private static var gespeichert: String?

    static var aktuell: String {
        if let c = gespeichert { return c }
        Ablage.ordnerAnlegen()
        if let vorhanden = try? String(contentsOf: Ablage.codeDatei, encoding: .utf8) {
            let getrimmt = vorhanden.trimmingCharacters(in: .whitespacesAndNewlines)
            if !getrimmt.isEmpty {
                gespeichert = getrimmt
                return getrimmt
            }
        }
        let neu = Zufall.kennung(24)
        try? neu.write(to: Ablage.codeDatei, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: Ablage.codeDatei.path)
        gespeichert = neu
        return neu
    }

    /// Erzeugt einen neuen Code. Alte Adressen werden damit ungueltig.
    static func neu() {
        let wert = Zufall.kennung(24)
        Ablage.ordnerAnlegen()
        try? wert.write(to: Ablage.codeDatei, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: Ablage.codeDatei.path)
        gespeichert = wert
    }

    static func stimmt(_ gegeben: String?) -> Bool {
        guard let gegeben, !gegeben.isEmpty else { return false }
        // Laufzeitkonstanter Vergleich, damit die Antwortzeit nichts verraet.
        let a = Array(gegeben.utf8), b = Array(aktuell.utf8)
        guard a.count == b.count else { return false }
        var unterschied: UInt8 = 0
        for i in 0..<a.count { unterschied |= a[i] ^ b[i] }
        return unterschied == 0
    }
}

enum Netz {
    /// Name, unter dem der Mac im lokalen Netz per mDNS erreichbar ist.
    static var bonjourName: String {
        let name = Host.current().name ?? "mac"
        return name.hasSuffix(".local") ? name : name + ".local"
    }

    /// IPv4-Adresse der aktiven Schnittstelle, als Rueckfallebene.
    static var lokaleAdresse: String {
        var adresse = "127.0.0.1"
        var zeiger: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&zeiger) == 0, let start = zeiger else { return adresse }
        defer { freeifaddrs(zeiger) }

        var eintrag: UnsafeMutablePointer<ifaddrs>? = start
        while let e = eintrag {
            let familie = e.pointee.ifa_addr.pointee.sa_family
            let name = String(cString: e.pointee.ifa_name)
            if familie == UInt8(AF_INET), name == "en0" || name == "en1" {
                var puffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(e.pointee.ifa_addr, socklen_t(e.pointee.ifa_addr.pointee.sa_len),
                               &puffer, socklen_t(puffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let gefunden = String(cString: puffer)
                    if !gefunden.hasPrefix("127.") { adresse = gefunden }
                }
            }
            eintrag = e.pointee.ifa_next
        }
        return adresse
    }
}
