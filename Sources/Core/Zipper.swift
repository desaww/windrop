import Foundation

/// Bundles several files, or a folder, into a single ZIP archive.
///
/// Why bundle at all: the browser on the receiving side asks for permission
/// the second time it downloads something automatically. One archive is one
/// download, no matter how much is inside. Folders cannot be sent any other
/// way either.
enum Zipper {

    /// Creates an archive in the staging folder and returns its path.
    /// Runs synchronously, so call it off the main thread.
    static func makeArchive(_ sources: [URL], log: (String) -> Void = { _ in }) -> URL? {
        guard !sources.isEmpty else { return nil }
        let fm = FileManager.default
        Storage.createFolders()

        let workFolder = Storage.staging.appendingPathComponent(RandomID.make(6))
        guard (try? fm.createDirectory(at: workFolder,
                                       withIntermediateDirectories: true)) != nil else { return nil }

        let name = archiveName(sources)
        let target = workFolder.appendingPathComponent(name + ".zip")

        // A single source is archived directly. Several sources are first
        // collected in one folder, using hard links so nothing is copied
        // needlessly.
        var collection: URL?
        let source: URL
        if sources.count == 1 {
            source = sources[0]
        } else {
            let folder = workFolder.appendingPathComponent(name)
            guard (try? fm.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else {
                try? fm.removeItem(at: workFolder)
                return nil
            }
            for item in sources {
                let itemTarget = Storage.freeName(in: folder, name: item.lastPathComponent)
                if (try? fm.linkItem(at: item, to: itemTarget)) == nil,
                   (try? fm.copyItem(at: item, to: itemTarget)) == nil {
                    log("Could not add to the archive: " + item.lastPathComponent)
                }
            }
            collection = folder
            source = folder
        }

        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        tool.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent",
                          source.path, target.path]
        tool.standardOutput = FileHandle.nullDevice
        tool.standardError = FileHandle.nullDevice

        do {
            try tool.run()
        } catch {
            try? fm.removeItem(at: workFolder)
            return nil
        }
        tool.waitUntilExit()

        if let folder = collection { try? fm.removeItem(at: folder) }

        guard tool.terminationStatus == 0, fm.fileExists(atPath: target.path) else {
            try? fm.removeItem(at: workFolder)
            return nil
        }
        return target
    }

    private static func archiveName(_ sources: [URL]) -> String {
        if sources.count == 1 {
            let name = sources[0].lastPathComponent
            let withoutExtension = (name as NSString).deletingPathExtension
            return FileNames.sanitize(withoutExtension.isEmpty ? name : withoutExtension)
        }
        return "WinDrop \(sources.count) files"
    }
}
