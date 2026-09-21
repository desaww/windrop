import Foundation

/// Rahmenformat nach RFC 6455. Serverseitige Rahmen werden nie maskiert,
/// Rahmen vom Browser sind immer maskiert.
enum WebSocketRahmen {

    static let handschlagGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    // MARK: Schreiben

    static func kodieren(_ nutzlast: Data, opcode: UInt8 = 0x1) -> Data {
        var aus = Data([0x80 | opcode])
        let n = nutzlast.count
        if n < 126 {
            aus.append(UInt8(n))
        } else if n < 65_536 {
            aus.append(126)
            aus.append(UInt8((n >> 8) & 0xFF))
            aus.append(UInt8(n & 0xFF))
        } else {
            aus.append(127)
            for verschiebung in stride(from: 56, through: 0, by: -8) {
                aus.append(UInt8((n >> verschiebung) & 0xFF))
            }
        }
        aus.append(nutzlast)
        return aus
    }

    static func kodieren(text: String, opcode: UInt8 = 0x1) -> Data {
        kodieren(Data(text.utf8), opcode: opcode)
    }

    // MARK: Lesen

    struct Gelesen {
        let opcode: UInt8
        let nutzlast: Data
        /// Wie viele Bytes des Puffers dieser Rahmen verbraucht hat.
        let verbraucht: Int
    }

    /// Liest genau einen Rahmen. `nil` bedeutet: noch nicht genug Daten im Puffer.
    static func dekodieren(_ puffer: Data) -> Gelesen? {
        let bytes = [UInt8](puffer)
        guard bytes.count >= 2 else { return nil }

        let opcode = bytes[0] & 0x0F
        let maskiert = (bytes[1] & 0x80) != 0
        var laenge = Int(bytes[1] & 0x7F)
        var index = 2

        if laenge == 126 {
            guard bytes.count >= 4 else { return nil }
            laenge = Int(bytes[2]) << 8 | Int(bytes[3])
            index = 4
        } else if laenge == 127 {
            guard bytes.count >= 10 else { return nil }
            laenge = 0
            for i in 2..<10 { laenge = laenge << 8 | Int(bytes[i]) }
            index = 10
        }

        // Nachrichten vom Browser sind winzig; alles darueber ist ein Fehler.
        guard laenge <= 1_000_000 else { return nil }

        var maske = [UInt8]()
        if maskiert {
            guard bytes.count >= index + 4 else { return nil }
            maske = Array(bytes[index..<index + 4])
            index += 4
        }

        guard bytes.count >= index + laenge else { return nil }
        var daten = Array(bytes[index..<index + laenge])
        if maskiert {
            for i in 0..<daten.count { daten[i] ^= maske[i % 4] }
        }
        return Gelesen(opcode: opcode, nutzlast: Data(daten), verbraucht: index + laenge)
    }
}
