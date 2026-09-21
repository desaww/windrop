import Cocoa
import UniformTypeIdentifiers

/// Die Teilen-Erweiterung. Sie taucht im Teilen-Menü von macOS auf, liest die
/// ausgewählten Dateien und lädt sie an die laufende WinDrop-App auf
/// 127.0.0.1 hoch. Mehr macht sie nicht – die ganze Logik steckt im Server.
class ShareViewController: NSViewController {

    private let titel = NSTextField(labelWithString: "An Windows senden")
    private let status = NSTextField(labelWithString: "Wird vorbereitet …")
    private let spinner = NSProgressIndicator()

    private var offen = 0
    private var fehlgeschlagen: [String] = []
    private var erfolgreich = 0

    override func loadView() {
        let flaeche = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 118))

        titel.font = .systemFont(ofSize: 13, weight: .semibold)
        titel.frame = NSRect(x: 20, y: 74, width: 280, height: 20)

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 20, y: 44, width: 280, height: 26)
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 2

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.frame = NSRect(x: 20, y: 18, width: 16, height: 16)
        spinner.startAnimation(nil)

        flaeche.addSubview(titel)
        flaeche.addSubview(status)
        flaeche.addSubview(spinner)
        view = flaeche
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        verarbeiten()
    }

    // MARK: Ablauf

    private func verarbeiten() {
        guard let eintraege = extensionContext?.inputItems as? [NSExtensionItem] else {
            fertig(text: "Nichts zum Senden gefunden.")
            return
        }

        var anbieter: [NSItemProvider] = []
        for eintrag in eintraege {
            anbieter.append(contentsOf: eintrag.attachments ?? [])
        }
        guard !anbieter.isEmpty else {
            fertig(text: "Nichts zum Senden gefunden.")
            return
        }

        offen = anbieter.count
        status.stringValue = anbieter.count == 1
            ? "Datei wird übertragen …"
            : "\(anbieter.count) Dateien werden übertragen …"

        let typ = UTType.fileURL.identifier
        for a in anbieter {
            guard a.hasItemConformingToTypeIdentifier(typ) else {
                abschlussEinzeln(fehler: "Nicht als Datei verfügbar")
                continue
            }
            a.loadItem(forTypeIdentifier: typ) { [weak self] eintrag, _ in
                guard let self else { return }
                var url: URL?
                if let daten = eintrag as? Data {
                    url = URL(dataRepresentation: daten, relativeTo: nil)
                } else if let direkt = eintrag as? URL {
                    url = direkt
                }
                guard let url else {
                    self.abschlussEinzeln(fehler: "Pfad nicht lesbar")
                    return
                }
                self.hochladen(url)
            }
        }
    }

    private func hochladen(_ url: URL) {
        // Ordner lassen sich nicht als Datenstrom hochladen. Sie muessen in
        // der App gepackt werden, dort gibt es das Ablagefenster dafuer.
        var istOrdner: ObjCBool = false
        let vorhanden = FileManager.default.fileExists(atPath: url.path, isDirectory: &istOrdner)
        guard vorhanden, !istOrdner.boolValue else {
            abschlussEinzeln(fehler: istOrdner.boolValue
                             ? "Ordner bitte ins Ablagefenster ziehen"
                             : "Datei nicht gefunden")
            return
        }

        let name = url.lastPathComponent
        let kodiert = name.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: ".-_"))) ?? "datei"

        guard let ziel = URL(string: "http://127.0.0.1:\(WinDropPort.nummer)/api/upload?name=\(kodiert)") else {
            abschlussEinzeln(fehler: "Adresse ungültig")
            return
        }

        var anfrage = URLRequest(url: ziel)
        anfrage.httpMethod = "POST"
        anfrage.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        anfrage.timeoutInterval = 600

        let aufgabe = URLSession.shared.uploadTask(with: anfrage, fromFile: url) {
            [weak self] _, antwort, fehler in
            guard let self else { return }
            if let fehler {
                let text = (fehler as NSError).code == NSURLErrorCannotConnectToHost
                    ? "WinDrop läuft nicht"
                    : fehler.localizedDescription
                self.abschlussEinzeln(fehler: text)
                return
            }
            if let http = antwort as? HTTPURLResponse, http.statusCode != 200 {
                self.abschlussEinzeln(fehler: "Server antwortete \(http.statusCode)")
                return
            }
            self.abschlussEinzeln(fehler: nil)
        }
        aufgabe.resume()
    }

    private func abschlussEinzeln(fehler: String?) {
        DispatchQueue.main.async {
            if let fehler {
                self.fehlgeschlagen.append(fehler)
            } else {
                self.erfolgreich += 1
            }
            self.offen -= 1
            guard self.offen <= 0 else { return }

            if self.fehlgeschlagen.isEmpty {
                self.fertig(text: self.erfolgreich == 1
                            ? "Gesendet."
                            : "\(self.erfolgreich) Dateien gesendet.")
            } else if self.erfolgreich == 0 {
                self.fertig(text: self.fehlgeschlagen[0]
                            + ". Läuft WinDrop in der Menüleiste?", wartezeit: 3.0)
            } else {
                self.fertig(text: "\(self.erfolgreich) gesendet, "
                            + "\(self.fehlgeschlagen.count) fehlgeschlagen.", wartezeit: 3.0)
            }
        }
    }

    private func fertig(text: String, wartezeit: TimeInterval = 0.9) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        status.stringValue = text
        DispatchQueue.main.asyncAfter(deadline: .now() + wartezeit) {
            self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }
}

/// Die Erweiterung teilt keinen Code mit der App, deshalb steht der Port hier
/// noch einmal. Wird er geändert, muss er an beiden Stellen geändert werden.
enum WinDropPort {
    static let nummer = 8787
}
