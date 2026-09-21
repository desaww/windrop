import Foundation

enum FileNames {

    private static let transliteration: [Character: String] = [
        "ä": "ae", "ö": "oe", "ü": "ue", "Ä": "Ae", "Ö": "Oe", "Ü": "Ue",
        "ß": "ss", "é": "e", "è": "e", "ê": "e", "á": "a", "à": "a", "â": "a",
        "í": "i", "ó": "o", "ô": "o", "ú": "u", "ç": "c", "ñ": "n",
    ]

    /// Plain ASCII fallback name. Modern browsers use filename*=UTF-8 anyway;
    /// this only matters for clients that ignore it.
    static func asciiFallback(_ name: String) -> String {
        var out = ""
        for character in name {
            let replacement = transliteration[character] ?? String(character)
            let clean = replacement.unicodeScalars.allSatisfy {
                $0.value > 32 && $0.value < 127 && $0 != "\"" && $0 != "\\"
            }
            out += clean ? replacement : "_"
        }
        return out.isEmpty ? "file" : out
    }

    /// Keeps a name from escaping the staging folder.
    static func sanitize(_ name: String) -> String {
        let bare = (name as NSString).lastPathComponent
        let clean = bare
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty || clean == "." || clean == ".." { return "file" }
        return String(clean.prefix(200))
    }
}
