import Foundation

/// Beobachtet den Outbox-Ordner. Alles, was dorthin gezogen wird, geht raus.
/// Gesendet wird erst, wenn die Dateigroesse zwischen zwei Blicken gleich
/// bleibt. Sonst wuerde eine noch kopierende Datei halb uebertragen.
final class OutboxWaechter {

    private let schlange: Warteschlange
    private let takt = DispatchQueue(label: "de.lennard.windrop.outbox")
    private var timer: DispatchSourceTimer?
    private var groessen: [String: Int] = [:]

    init(schlange: Warteschlange) {
        self.schlange = schlange
    }

    func starten() {
        Ablage.ordnerAnlegen()
        let t = DispatchSource.makeTimerSource(queue: takt)
        t.schedule(deadline: .now() + 1, repeating: 0.7)
        t.setEventHandler { [weak self] in self?.nachsehen() }
        t.resume()
        timer = t
    }

    private func nachsehen() {
        let fm = FileManager.default
        guard let inhalt = try? fm.contentsOfDirectory(
            at: Ablage.outbox,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return }

        var gesehen = Set<String>()

        for datei in inhalt {
            let name = datei.lastPathComponent
            if name.hasPrefix(".") { continue }
            guard let werte = try? datei.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  werte.isRegularFile == true, let groesse = werte.fileSize else { continue }

            gesehen.insert(datei.path)

            if groessen[datei.path] == groesse {
                groessen.removeValue(forKey: datei.path)
                let ordner = Ablage.zwischenlager.appendingPathComponent(Zufall.kennung(6))
                try? fm.createDirectory(at: ordner, withIntermediateDirectories: true)
                let ziel = ordner.appendingPathComponent(name)
                if (try? fm.moveItem(at: datei, to: ziel)) != nil {
                    schlange.einreihen(pfad: ziel, archivieren: true)
                }
            } else {
                groessen[datei.path] = groesse
            }
        }

        for pfad in groessen.keys where !gesehen.contains(pfad) {
            groessen.removeValue(forKey: pfad)
        }
    }
}
