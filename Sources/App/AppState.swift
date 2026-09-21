import Foundation
import AppKit
import Network

/// Holds the state for the interface and runs the server.
///
/// Deliberately not @MainActor: the callbacks arrive on server threads and
/// are hopped onto the main thread by hand. Under Swift 5 that is easier to
/// follow than actor gymnastics.
final class AppState: ObservableObject {

    @Published var running = false
    @Published var startError: String?
    @Published var receiverNames: [String] = []
    @Published var transfers: [TransferSnapshot] = []
    @Published var log: [String] = []
    @Published var packing = false

    let settings = AppSettings.shared
    let history = History()

    private let queue = TransferQueue()
    private var server: HTTPServer?
    private var watcher: OutboxWatcher?
    private var pathMonitor: NWPathMonitor?
    private var wakeObserver: NSObjectProtocol?
    private var lastAddress = ""
    private let packQueue = DispatchQueue(label: "de.lennard.windrop.zip")

    var connected: Bool { !receiverNames.isEmpty }

    var statusText: String {
        if startError != nil { return tr("Not running", "Läuft nicht") }
        if receiverNames.isEmpty {
            return running
                ? tr("Waiting for the Windows tab", "Wartet auf den Windows-Tab")
                : tr("Starting the server", "Server startet")
        }
        return receiverNames.count == 1
            ? tr("Connected to ", "Verbunden mit ") + receiverNames[0]
            : "\(receiverNames.count) " + tr("receivers connected", "Empfänger verbunden")
    }

    var addressByName: String {
        "http://\(LocalNetwork.bonjourName):\(WinDropInfo.port)/?t=\(AccessToken.current)"
    }

    var addressByIP: String {
        "http://\(LocalNetwork.ipAddress):\(WinDropInfo.port)/?t=\(AccessToken.current)"
    }

    init() {
        Storage.createFolders()

        queue.onChange = { [weak self] snapshots, names in
            DispatchQueue.main.async {
                guard let self else { return }
                self.transfers = Array(snapshots.reversed())
                self.receiverNames = names
            }
        }
        queue.onLog = { [weak self] line in
            DispatchQueue.main.async { self?.note(line) }
        }
        queue.onFinish = { [weak self] name, size, success, reason in
            DispatchQueue.main.async {
                self?.recordFinish(name: name, size: size, success: success, reason: reason)
            }
        }
        queue.start()

        Storage.restoreStaging { line in
            print(line)
        }

        startServer()

        let watcher = OutboxWatcher(queue: queue)
        watcher.start()
        self.watcher = watcher

        Notifier.requestPermission()
        observeWake()
        observeNetwork()
    }

    // MARK: Server

    private func startServer() {
        let server = HTTPServer(queue: queue)
        server.onLog = { [weak self] line in
            DispatchQueue.main.async { self?.note(line) }
        }
        server.onStatus = { [weak self] ready in
            DispatchQueue.main.async { self?.running = ready }
        }
        do {
            try server.start()
            self.server = server
            startError = nil
            note(Format.time() + " WinDrop \(WinDropInfo.version) ready")
        } catch {
            startError = error.localizedDescription
            note(Format.time() + " Could not start: " + error.localizedDescription)
        }
    }

    func restartServer() {
        server?.stop()
        server = nil
        // Give the system a moment to release the port.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startServer()
        }
    }

    /// After waking up, old connections are dead. Restarting the server is
    /// the most reliable way back to a clean state; the receiving page
    /// reconnects on its own.
    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.note(Format.time() + " Mac woke up – restarting the server")
            self.restartServer()
        }
    }

    /// When the Mac changes networks its IP address changes too, and the
    /// listener has to be set up again on the new interface.
    private func observeNetwork() {
        lastAddress = LocalNetwork.ipAddress
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let now = LocalNetwork.ipAddress
                guard now != self.lastAddress else { return }
                self.lastAddress = now
                self.note(Format.time() + " Network changed (\(now)) – restarting the server")
                self.restartServer()
            }
        }
        monitor.start(queue: DispatchQueue(label: "de.lennard.windrop.path"))
        pathMonitor = monitor
    }

    // MARK: Sending

    func send(_ urls: [URL]) {
        let fm = FileManager.default
        var found: [(url: URL, isFolder: Bool)] = []

        for url in urls {
            var isFolder: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isFolder) else {
                note(Format.time() + " Not found: " + url.lastPathComponent)
                continue
            }
            found.append((url, isFolder.boolValue))
        }
        guard !found.isEmpty else { return }

        // Several items at once: one archive instead of many downloads.
        if settings.bundleAsZip, found.count > 1 {
            packAndSend(found.map { $0.url })
            return
        }

        for item in found {
            if item.isFolder {
                // Folders only travel as an archive, no matter the setting.
                packAndSend([item.url])
            } else {
                queue.enqueue(path: item.url, cleanUpAfterSend: false)
            }
        }
    }

    private func packAndSend(_ sources: [URL]) {
        let description = sources.count == 1
            ? sources[0].lastPathComponent
            : "\(sources.count) " + tr("items", "Objekte")
        packing = true
        note(Format.time() + " Packing \(description) into a ZIP archive …")

        packQueue.async { [weak self] in
            let result = Zipper.makeArchive(sources)
            DispatchQueue.main.async {
                guard let self else { return }
                self.packing = false
                guard let archive = result else {
                    self.note(Format.time() + " Packing failed: " + description)
                    if self.settings.notifyOnFailure {
                        Notifier.show(title: "WinDrop",
                                      body: tr("Packing failed: ", "Packen fehlgeschlagen: ")
                                          + description)
                    }
                    return
                }
                self.queue.enqueue(path: archive, cleanUpAfterSend: true)
            }
        }
    }

    private func recordFinish(name: String, size: Int, success: Bool, reason: String) {
        history.add(name: name, size: size, success: success, reason: reason)
        if success, settings.notifyOnSuccess {
            Notifier.show(title: tr("Delivered", "Zugestellt"), body: name)
        }
        if !success, settings.notifyOnFailure {
            Notifier.show(title: tr("Not sent", "Nicht gesendet"),
                          body: reason.isEmpty ? name : name + " – " + reason)
        }
    }

    // MARK: Other actions from the interface

    func retry(_ id: String) {
        queue.retry(id: id)
    }

    func clearFinished() {
        queue.clearFinished()
    }

    func copyAddress() {
        copyToPasteboard(addressByName, "Address")
    }

    func copyIPAddress() {
        copyToPasteboard(addressByIP, "IP address")
    }

    private func copyToPasteboard(_ text: String, _ what: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        note(Format.time() + " \(what) copied to the clipboard")
    }

    func regenerateToken() {
        AccessToken.regenerate()
        note(Format.time() + " New access token – reopen the address on the Windows laptop")
        objectWillChange.send()
    }

    private func note(_ line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    func quit() {
        server?.stop()
        NSApplication.shared.terminate(nil)
    }
}
