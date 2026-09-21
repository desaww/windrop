import Cocoa
import UniformTypeIdentifiers

/// The share extension. It shows up in the macOS share menu, reads the
/// selected files and uploads them to the running WinDrop app on 127.0.0.1.
/// That is all it does - the logic lives in the server.
class ShareViewController: NSViewController {

    private let titleLabel = NSTextField(labelWithString: tr("Send to Windows",
                                                            "An Windows senden"))
    private let status = NSTextField(labelWithString: tr("Preparing …",
                                                         "Wird vorbereitet …"))
    private let spinner = NSProgressIndicator()

    private var open = 0
    private var failures: [String] = []
    private var succeeded = 0

    override func loadView() {
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 118))

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.frame = NSRect(x: 20, y: 74, width: 280, height: 20)

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 20, y: 44, width: 280, height: 26)
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 2

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.frame = NSRect(x: 20, y: 18, width: 16, height: 16)
        spinner.startAnimation(nil)

        canvas.addSubview(titleLabel)
        canvas.addSubview(status)
        canvas.addSubview(spinner)
        view = canvas
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        ShareLanguage.refreshFromApp()
        process()
    }

    // MARK: Flow

    private func process() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            finish(text: tr("Nothing to send.", "Nichts zu senden."))
            return
        }

        var providers: [NSItemProvider] = []
        for item in items {
            providers.append(contentsOf: item.attachments ?? [])
        }
        guard !providers.isEmpty else {
            finish(text: tr("Nothing to send.", "Nichts zu senden."))
            return
        }

        open = providers.count
        status.stringValue = providers.count == 1
            ? tr("Sending the file …", "Datei wird gesendet …")
            : "\(providers.count) " + tr("files are being sent …",
                                         "Dateien werden gesendet …")

        let type = UTType.fileURL.identifier
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(type) else {
                finishOne(error: tr("Not available as a file",
                                    "Liegt nicht als Datei vor"))
                continue
            }
            provider.loadItem(forTypeIdentifier: type) { [weak self] item, _ in
                guard let self else { return }
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let direct = item as? URL {
                    url = direct
                }
                guard let url else {
                    self.finishOne(error: tr("Path not readable", "Pfad nicht lesbar"))
                    return
                }
                self.upload(url)
            }
        }
    }

    private func upload(_ url: URL) {
        // Folders cannot be uploaded as a stream. They have to be packed by
        // the app, which is what the drop window is for.
        var isFolder: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
        guard exists, !isFolder.boolValue else {
            finishOne(error: isFolder.boolValue
                      ? tr("Drag folders into the drop window instead",
                           "Ordner bitte ins Ablagefenster ziehen")
                      : tr("File not found", "Datei nicht gefunden"))
            return
        }

        let name = url.lastPathComponent
        let encoded = name.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: ".-_"))) ?? "file"

        guard let target = URL(string: "http://127.0.0.1:\(WinDropPort.number)/api/upload?name=\(encoded)") else {
            finishOne(error: tr("Invalid address", "Ungültige Adresse"))
            return
        }

        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600

        let task = URLSession.shared.uploadTask(with: request, fromFile: url) {
            [weak self] _, response, error in
            guard let self else { return }
            if let error {
                let text = (error as NSError).code == NSURLErrorCannotConnectToHost
                    ? tr("WinDrop is not running", "WinDrop läuft nicht")
                    : error.localizedDescription
                self.finishOne(error: text)
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                self.finishOne(error: tr("Server answered ", "Server antwortete mit ")
                               + "\(http.statusCode)")
                return
            }
            self.finishOne(error: nil)
        }
        task.resume()
    }

    private func finishOne(error: String?) {
        DispatchQueue.main.async {
            if let error {
                self.failures.append(error)
            } else {
                self.succeeded += 1
            }
            self.open -= 1
            guard self.open <= 0 else { return }

            if self.failures.isEmpty {
                self.finish(text: self.succeeded == 1
                            ? tr("Sent.", "Gesendet.")
                            : "\(self.succeeded) " + tr("files sent.", "Dateien gesendet."))
            } else if self.succeeded == 0 {
                self.finish(text: self.failures[0]
                            + tr(". Is WinDrop running in the menu bar?",
                                 ". Läuft WinDrop in der Menüleiste?"), delay: 3.0)
            } else {
                self.finish(text: "\(self.succeeded) " + tr("sent, ", "gesendet, ")
                            + "\(self.failures.count) "
                            + tr("failed.", "fehlgeschlagen."), delay: 3.0)
            }
        }
    }

    private func finish(text: String, delay: TimeInterval = 0.9) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        status.stringValue = text
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }
}

/// The extension shares no code with the app, so the port is repeated here.
/// If it is changed, it has to be changed in both places.
enum WinDropPort {
    static let number = 8787
}

/// Which language this window speaks.
///
/// A share extension runs in its own sandbox and cannot read the settings of
/// the app, so the choice is remembered here and refreshed from the running
/// app after every use. Consequence: right after the language is switched,
/// the share window shows the previous language once.
enum ShareLanguage {
    private static let key = "windropLanguage"

    /// Taken once per run, so a refresh arriving mid-flight cannot leave
    /// half of this window in the other language.
    static let current: String = UserDefaults.standard.string(forKey: key) ?? "en"

    static func refreshFromApp() {
        guard let url = URL(string: "http://127.0.0.1:\(WinDropPort.number)/api/info") else {
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let language = json["language"] as? String else { return }
            UserDefaults.standard.set(language, forKey: key)
        }.resume()
    }
}

func tr(_ english: String, _ german: String) -> String {
    ShareLanguage.current == "de" ? german : english
}
