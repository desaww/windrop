import Cocoa
import UniformTypeIdentifiers

/// The share extension. It shows up in the macOS share menu, reads the
/// selected files and uploads them to the running WinDrop app on 127.0.0.1.
/// That is all it does - the logic lives in the server.
class ShareViewController: NSViewController {

    private let titleLabel = NSTextField(labelWithString: "Send to Windows")
    private let status = NSTextField(labelWithString: "Preparing …")
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
        process()
    }

    // MARK: Flow

    private func process() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            finish(text: "Nothing to send.")
            return
        }

        var providers: [NSItemProvider] = []
        for item in items {
            providers.append(contentsOf: item.attachments ?? [])
        }
        guard !providers.isEmpty else {
            finish(text: "Nothing to send.")
            return
        }

        open = providers.count
        status.stringValue = providers.count == 1
            ? "Sending the file …"
            : "Sending \(providers.count) files …"

        let type = UTType.fileURL.identifier
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(type) else {
                finishOne(error: "Not available as a file")
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
                    self.finishOne(error: "Path not readable")
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
                      ? "Drag folders into the drop window instead"
                      : "File not found")
            return
        }

        let name = url.lastPathComponent
        let encoded = name.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: ".-_"))) ?? "file"

        guard let target = URL(string: "http://127.0.0.1:\(WinDropPort.number)/api/upload?name=\(encoded)") else {
            finishOne(error: "Invalid address")
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
                    ? "WinDrop is not running"
                    : error.localizedDescription
                self.finishOne(error: text)
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                self.finishOne(error: "Server answered \(http.statusCode)")
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
                            ? "Sent."
                            : "\(self.succeeded) files sent.")
            } else if self.succeeded == 0 {
                self.finish(text: self.failures[0]
                            + ". Is WinDrop running in the menu bar?", delay: 3.0)
            } else {
                self.finish(text: "\(self.succeeded) sent, "
                            + "\(self.failures.count) failed.", delay: 3.0)
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
