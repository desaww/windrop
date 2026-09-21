import Foundation

enum Dateiname {

    private static let umschrift: [Character: String] = [
        "ä": "ae", "ö": "oe", "ü": "ue", "Ä": "Ae", "Ö": "Oe", "Ü": "Ue",
        "ß": "ss", "é": "e", "è": "e", "ê": "e", "á": "a", "à": "a", "â": "a",
        "í": "i", "ó": "o", "ô": "o", "ú": "u", "ç": "c", "ñ": "n",
    ]

    /// Reiner ASCII-Name als Rueckfallebene. Moderne Browser nehmen ohnehin
    /// filename*=UTF-8; nur wenn ein Client das ignoriert, greift dieser Name.
    static func asciiErsatz(_ name: String) -> String {
        var aus = ""
        for zeichen in name {
            let ersatz = umschrift[zeichen] ?? String(zeichen)
            let sauber = ersatz.unicodeScalars.allSatisfy {
                $0.value > 32 && $0.value < 127 && $0 != "\"" && $0 != "\\"
            }
            aus += sauber ? ersatz : "_"
        }
        return aus.isEmpty ? "datei" : aus
    }

    /// Schuetzt davor, dass ein Name aus dem Zwischenlager ausbricht.
    static func saeubern(_ name: String) -> String {
        let nurName = (name as NSString).lastPathComponent
        let sauber = nurName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if sauber.isEmpty || sauber == "." || sauber == ".." { return "datei" }
        return String(sauber.prefix(200))
    }
}
