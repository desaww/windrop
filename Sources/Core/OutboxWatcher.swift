import Foundation

/// Watches the outbox folder. Anything dropped in there goes out.
/// A file is only sent once its size stays the same between two looks,
/// otherwise a file still being copied would be transferred half-finished.
final class OutboxWatcher {

    private let queue: TransferQueue
    private let pollQueue = DispatchQueue(label: "de.lennard.windrop.outbox")
    private var timer: DispatchSourceTimer?
    private var sizes: [String: Int] = [:]

    init(queue: TransferQueue) {
        self.queue = queue
    }

    func start() {
        Storage.createFolders()
        let t = DispatchSource.makeTimerSource(queue: pollQueue)
        t.schedule(deadline: .now() + 1, repeating: 0.7)
        t.setEventHandler { [weak self] in self?.look() }
        t.resume()
        timer = t
    }

    private func look() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: Storage.outbox,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return }

        var seen = Set<String>()

        for file in contents {
            let name = file.lastPathComponent
            if name.hasPrefix(".") { continue }
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true, let size = values.fileSize else { continue }

            seen.insert(file.path)

            if sizes[file.path] == size {
                sizes.removeValue(forKey: file.path)
                let folder = Storage.staging.appendingPathComponent(RandomID.make(6))
                try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let target = folder.appendingPathComponent(name)
                if (try? fm.moveItem(at: file, to: target)) != nil {
                    queue.enqueue(path: target, cleanUpAfterSend: true)
                }
            } else {
                sizes[file.path] = size
            }
        }

        for path in sizes.keys where !seen.contains(path) {
            sizes.removeValue(forKey: path)
        }
    }
}
