import Foundation
import Security   // SecRandomCopyBytes
import Darwin     // getifaddrs

enum WinDropInfo {
    static let version = "0.5"
    static let port: UInt16 = 8787
}

enum RandomID {
    /// URL-safe random identifier.
    static func make(_ bytes: Int) -> String {
        var raw = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &raw)
        return Data(raw).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum Format {
    static func size(_ bytes: Int) -> String {
        var value = Double(bytes)
        let units = ["B", "KB", "MB", "GB"]
        var i = 0
        while value >= 1024, i < units.count - 1 {
            value /= 1024
            i += 1
        }
        return i == 0 ? "\(bytes) B" : String(format: "%.1f %@", value, units[i])
    }

    static func time() -> String {
        let f = DateFormatter()
        f.dateFormat = "[HH:mm:ss]"
        return f.string(from: Date())
    }
}

enum JSONHelper {
    static func text(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    static func dictionary(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// Everything WinDrop keeps on disk lives in ~/WinDrop.
enum Storage {
    static var base: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("WinDrop")
    }
    static var outbox: URL { base.appendingPathComponent("Outbox") }
    static var staging: URL { base.appendingPathComponent(".stage") }
    static var tokenFile: URL { base.appendingPathComponent("token.txt") }

    static func createFolders() {
        for folder in [base, outbox, staging] {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    /// Finds an unused name in the target folder so nothing gets overwritten.
    static func freeName(in folder: URL, name: String) -> URL {
        let fm = FileManager.default
        var target = folder.appendingPathComponent(name)
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var i = 1
        while fm.fileExists(atPath: target.path) {
            let candidate = ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)"
            target = folder.appendingPathComponent(candidate)
            i += 1
        }
        return target
    }

    /// Cleans up after a successful transfer.
    ///
    /// Only files WinDrop itself moved into the staging area are removed,
    /// which means the outbox, the share extension and generated archives.
    /// Originals that were merely referenced (drag and drop, file picker)
    /// are never touched.
    static func cleanUp(_ transfer: Transfer) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            let fm = FileManager.default
            let source = transfer.path
            guard source.path.hasPrefix(staging.path) else { return }
            try? fm.removeItem(at: source)
            let folder = source.deletingLastPathComponent()
            if folder.path.hasPrefix(staging.path), folder.path != staging.path {
                try? fm.removeItem(at: folder)
            }
        }
    }

    /// After a restart old offers are void. Whatever is left in the staging
    /// area goes back into the outbox.
    static func restoreStaging(log: (String) -> Void) {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: staging,
                                                        includingPropertiesForKeys: nil) else { return }
        for folder in folders {
            guard let files = try? fm.contentsOfDirectory(at: folder,
                                                          includingPropertiesForKeys: nil) else { continue }
            for file in files {
                let target = freeName(in: outbox, name: file.lastPathComponent)
                if (try? fm.moveItem(at: file, to: target)) != nil {
                    log("Restored to outbox: \(target.lastPathComponent)")
                }
            }
            try? fm.removeItem(at: folder)
        }
    }
}

/// The shared secret that guards the server. Without it the server answers
/// 403 and hands out neither the page nor a file.
enum AccessToken {
    private static var cached: String?

    static var current: String {
        if let token = cached { return token }
        Storage.createFolders()
        if let stored = try? String(contentsOf: Storage.tokenFile, encoding: .utf8) {
            let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                cached = trimmed
                return trimmed
            }
        }
        let fresh = RandomID.make(24)
        write(fresh)
        return fresh
    }

    /// Creates a new token. Any address handed out before stops working.
    static func regenerate() {
        write(RandomID.make(24))
    }

    private static func write(_ token: String) {
        Storage.createFolders()
        try? token.write(to: Storage.tokenFile, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: Storage.tokenFile.path)
        cached = token
    }

    static func matches(_ given: String?) -> Bool {
        guard let given, !given.isEmpty else { return false }
        // Constant-time comparison so the response time gives nothing away.
        let a = Array(given.utf8), b = Array(current.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for i in 0..<a.count { difference |= a[i] ^ b[i] }
        return difference == 0
    }
}

enum LocalNetwork {
    /// The name this Mac answers to on the local network via mDNS.
    static var bonjourName: String {
        let name = Host.current().name ?? "mac"
        return name.hasSuffix(".local") ? name : name + ".local"
    }

    /// IPv4 address of the active interface, used as a fallback.
    static var ipAddress: String {
        var address = "127.0.0.1"
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return address }
        defer { freeifaddrs(pointer) }

        var entry: UnsafeMutablePointer<ifaddrs>? = first
        while let e = entry {
            let family = e.pointee.ifa_addr.pointee.sa_family
            let name = String(cString: e.pointee.ifa_name)
            if family == UInt8(AF_INET), name == "en0" || name == "en1" {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(e.pointee.ifa_addr, socklen_t(e.pointee.ifa_addr.pointee.sa_len),
                               &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let found = String(cString: buffer)
                    if !found.hasPrefix("127.") { address = found }
                }
            }
            entry = e.pointee.ifa_next
        }
        return address
    }
}
