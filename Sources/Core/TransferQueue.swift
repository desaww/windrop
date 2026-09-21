import Foundation

enum TransferStatus: String {
    case waiting, offered, sending, done, failed
}

final class Transfer {
    let id: String
    var path: URL
    let name: String
    let size: Int
    /// True for files WinDrop moved into the staging area itself. Those are
    /// deleted once they have been delivered.
    let cleanUpAfterSend: Bool

    var status: TransferStatus = .waiting
    var sent: Int = 0
    var attempts: Int = 0
    var offeredAt: Date = .distantPast
    var finishedAt: Date?
    var reason: String = ""

    init(path: URL, size: Int, cleanUpAfterSend: Bool) {
        self.id = RandomID.make(9)
        self.path = path
        self.name = path.lastPathComponent
        self.size = size
        self.cleanUpAfterSend = cleanUpAfterSend
    }
}

/// Immutable snapshot for the user interface, so SwiftUI never looks at
/// mutable objects.
struct TransferSnapshot: Identifiable, Equatable {
    let id: String
    let name: String
    let size: Int
    let sent: Int
    let status: String
    let reason: String

    var fraction: Double { size > 0 ? Double(sent) / Double(size) : 0 }
}

final class Receiver {
    let id = UUID()
    let address: String
    let kind: String            // "ws" or "sse"
    let write: (String) -> Void
    var alive = true

    init(address: String, kind: String, write: @escaping (String) -> Void) {
        self.address = address
        self.kind = kind
        self.write = write
    }

    func send(_ message: [String: Any]) {
        guard alive, let text = JSONHelper.text(message) else { return }
        write(text)
    }
}

/// Owns the queue and the connected receivers.
///
/// Locking uses a recursive lock on purpose. A serial DispatchQueue would be
/// dangerous here: as soon as one locked method calls another, the program
/// deadlocks.
final class TransferQueue {

    static let offerTimeout: TimeInterval = 30
    static let maxAttempts = 3
    static let keepFinishedFor: TimeInterval = 3600

    private let lock = NSRecursiveLock()
    private var transfers: [Transfer] = []
    private var receivers: [Receiver] = []
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "de.lennard.windrop.scheduler")

    /// Called after every change so the interface can refresh.
    var onChange: (([TransferSnapshot], [String]) -> Void)?
    var onLog: ((String) -> Void)?
    /// Name, size, success, reason - used for history and notifications.
    var onFinish: ((String, Int, Bool, String) -> Void)?

    private func locked<T>(_ block: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return block()
    }

    // MARK: Start

    func start() {
        let t = DispatchSource.makeTimerSource(queue: timerQueue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    // MARK: Receivers

    func add(_ receiver: Receiver) {
        locked { receivers.append(receiver) }
        log("Receiver connected: \(receiver.address) (\(receiver.kind.uppercased()))")
        receiver.send(["type": "welcome",
                       "device": Host.current().localizedName ?? "Mac",
                       "version": WinDropInfo.version])
        for transfer in locked({ transfers.filter { $0.status == .offered } }) {
            receiver.send(offer(transfer))
        }
        notifyChange()
    }

    func remove(_ receiver: Receiver) {
        receiver.alive = false
        locked { receivers.removeAll { $0.id == receiver.id } }
        log("Receiver disconnected: \(receiver.address)")
        notifyChange()
    }

    private func broadcast(_ message: [String: Any]) {
        for receiver in locked({ receivers }) { receiver.send(message) }
    }

    // MARK: Enqueue

    @discardableResult
    func enqueue(path: URL, cleanUpAfterSend: Bool = false) -> Transfer? {
        guard let values = try? FileManager.default.attributesOfItem(atPath: path.path),
              let size = values[.size] as? Int else { return nil }
        let transfer = Transfer(path: path, size: size, cleanUpAfterSend: cleanUpAfterSend)
        locked { transfers.append(transfer) }
        log("Queued: \(transfer.name) (\(Format.size(size)))")
        notifyChange()
        return transfer
    }

    func transfer(id: String) -> Transfer? {
        locked { transfers.first { $0.id == id } }
    }

    func snapshots() -> [TransferSnapshot] {
        locked { transfers.map(snapshot) }
    }

    func receiverNames() -> [String] {
        locked { receivers.map { $0.address } }
    }

    func hasReceiver() -> Bool {
        locked { !receivers.isEmpty }
    }

    private func snapshot(_ t: Transfer) -> TransferSnapshot {
        TransferSnapshot(id: t.id, name: t.name, size: t.size,
                         sent: t.sent, status: t.status.rawValue, reason: t.reason)
    }

    private func offer(_ t: Transfer) -> [String: Any] {
        [
            "type": "file",
            "id": t.id,
            "name": t.name,
            "size": t.size,
            "size_text": Format.size(t.size),
            "url": "/f/\(t.id)?t=\(AccessToken.current)",
        ]
    }

    // MARK: Scheduler

    /// Runs on a timer and never offers more than one file at a time.
    private func tick() {
        var outgoing: [[String: Any]] = []

        locked {
            var active = transfers.filter { $0.status == .offered || $0.status == .sending }

            for t in active where t.status == .offered {
                guard Date().timeIntervalSince(t.offeredAt) > Self.offerTimeout else { continue }
                if t.attempts >= Self.maxAttempts {
                    t.status = .failed
                    t.reason = tr("Receiver did not respond",
                                  "Empfänger antwortet nicht")
                    t.finishedAt = Date()
                    log("Giving up: \(t.name) (no response)")
                    outgoing.append(["type": "error", "id": t.id, "reason": t.reason])
                    reportFinish(t.name, t.size, false, t.reason)
                } else {
                    t.status = .waiting
                    log("Retrying: \(t.name)")
                }
                active.removeAll { $0.id == t.id }
            }

            if active.isEmpty, !receivers.isEmpty,
               let next = transfers.first(where: { $0.status == .waiting }) {
                next.status = .offered
                next.attempts += 1
                next.offeredAt = Date()
                next.sent = 0
                outgoing.append(offer(next))
                log("Offered: \(next.name) (attempt \(next.attempts))")
            }

            transfers.removeAll { t in
                guard let finished = t.finishedAt else { return false }
                return (t.status == .done || t.status == .failed)
                    && Date().timeIntervalSince(finished) > Self.keepFinishedFor
            }
        }

        for message in outgoing { broadcast(message) }
        if !outgoing.isEmpty { notifyChange() }
    }

    // MARK: State changes, called by the server

    func markSending(_ t: Transfer) {
        locked {
            t.status = .sending
            t.sent = 0
        }
        notifyChange()
    }

    func progress(_ t: Transfer, sent: Int) {
        locked { t.sent = sent }
        broadcast(["type": "progress", "id": t.id, "sent": sent])
        notifyChange()
    }

    func complete(_ t: Transfer) {
        let duration = max(Date().timeIntervalSince(t.offeredAt), 0.001)
        locked {
            t.status = .done
            t.sent = t.size
            t.finishedAt = Date()
        }
        log("Delivered: \(t.name) (\(Format.size(t.size)) in "
            + String(format: "%.1f", duration) + " s, "
            + Format.size(Int(Double(t.size) / duration)) + "/s)")
        broadcast(["type": "done", "id": t.id])
        if t.cleanUpAfterSend { Storage.cleanUp(t) }
        reportFinish(t.name, t.size, true, "")
        notifyChange()
    }

    func abort(_ t: Transfer) {
        let sent = t.sent
        locked { t.status = .waiting }
        log("Transfer of \(t.name) broke off after \(Format.size(sent)) – back in the queue")
        notifyChange()
    }

    // MARK: Actions from the interface

    /// Puts a failed transfer back into the queue.
    func retry(id: String) {
        var name = ""
        locked {
            guard let t = transfers.first(where: { $0.id == id }), t.status == .failed else { return }
            t.status = .waiting
            t.attempts = 0
            t.sent = 0
            t.reason = ""
            t.finishedAt = nil
            name = t.name
        }
        guard !name.isEmpty else { return }
        log("Queued again: \(name)")
        notifyChange()
    }

    /// Removes finished and failed entries from the list.
    func clearFinished() {
        locked {
            transfers.removeAll { $0.status == .done || $0.status == .failed }
        }
        notifyChange()
    }

    // MARK: Helpers

    private func reportFinish(_ name: String, _ size: Int, _ success: Bool, _ reason: String) {
        DispatchQueue.main.async { self.onFinish?(name, size, success, reason) }
    }

    private func log(_ text: String) {
        let line = Format.time() + " " + text
        DispatchQueue.main.async { self.onLog?(line) }
    }

    private func notifyChange() {
        let snapshots = locked { transfers.map(snapshot) }
        let names = locked { receivers.map { $0.address } }
        DispatchQueue.main.async { self.onChange?(snapshots, names) }
    }
}
