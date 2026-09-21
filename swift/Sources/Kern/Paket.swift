import Foundation

/// Buendelt mehrere Dateien oder einen Ordner zu einem einzigen ZIP-Archiv.
///
/// Warum ueberhaupt buendeln: Der Browser am Windows-Laptop fragt beim
/// zweiten automatischen Download nach Erlaubnis. Ein Archiv ist ein
/// Download, egal wie viel drinsteckt. Ausserdem lassen sich Ordner nur so
/// verschicken.
enum Paket {

    /// Legt ein ZIP im Zwischenlager an und gibt dessen Pfad zurueck.
    /// Laeuft synchron, also bitte im Hintergrund aufrufen.
    static func schnueren(_ quellen: [URL], melden: (String) -> Void = { _ in }) -> URL? {
        guard !quellen.isEmpty else { return nil }
        let fm = FileManager.default
        Ablage.ordnerAnlegen()

        let arbeitsordner = Ablage.zwischenlager.appendingPathComponent(Zufall.kennung(6))
        guard (try? fm.createDirectory(at: arbeitsordner,
                                       withIntermediateDirectories: true)) != nil else { return nil }

        let name = paketname(quellen)
        let ziel = arbeitsordner.appendingPathComponent(name + ".zip")

        // Bei genau einer Quelle wird sie direkt gepackt. Bei mehreren
        // sammelt ein Zwischenordner sie ein - mit harten Verknuepfungen,
        // damit nichts unnoetig kopiert wird.
        var sammel: URL?
        let quelle: URL
        if quellen.count == 1 {
            quelle = quellen[0]
        } else {
            let ordner = arbeitsordner.appendingPathComponent(name)
            guard (try? fm.createDirectory(at: ordner, withIntermediateDirectories: true)) != nil else {
                try? fm.removeItem(at: arbeitsordner)
                return nil
            }
            for einzeln in quellen {
                let unterziel = Ablage.freierName(in: ordner, name: einzeln.lastPathComponent)
                if (try? fm.linkItem(at: einzeln, to: unterziel)) == nil,
                   (try? fm.copyItem(at: einzeln, to: unterziel)) == nil {
                    melden("Konnte nicht mitpacken: " + einzeln.lastPathComponent)
                }
            }
            sammel = ordner
            quelle = ordner
        }

        let werkzeug = Process()
        werkzeug.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        werkzeug.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent",
                              quelle.path, ziel.path]
        werkzeug.standardOutput = FileHandle.nullDevice
        werkzeug.standardError = FileHandle.nullDevice

        do {
            try werkzeug.run()
        } catch {
            try? fm.removeItem(at: arbeitsordner)
            return nil
        }
        werkzeug.waitUntilExit()

        if let ordner = sammel { try? fm.removeItem(at: ordner) }

        guard werkzeug.terminationStatus == 0, fm.fileExists(atPath: ziel.path) else {
            try? fm.removeItem(at: arbeitsordner)
            return nil
        }
        return ziel
    }

    private static func paketname(_ quellen: [URL]) -> String {
        if quellen.count == 1 {
            let name = quellen[0].lastPathComponent
            let ohneEndung = (name as NSString).deletingPathExtension
            return Dateiname.saeubern(ohneEndung.isEmpty ? name : ohneEndung)
        }
        return "WinDrop \(quellen.count) Dateien"
    }
}
