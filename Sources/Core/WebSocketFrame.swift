import Foundation

/// Frame format per RFC 6455. Server frames are never masked, frames coming
/// from the browser always are.
enum WebSocketFrame {

    static let handshakeGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    // MARK: Writing

    static func encode(_ payload: Data, opcode: UInt8 = 0x1) -> Data {
        var out = Data([0x80 | opcode])
        let n = payload.count
        if n < 126 {
            out.append(UInt8(n))
        } else if n < 65_536 {
            out.append(126)
            out.append(UInt8((n >> 8) & 0xFF))
            out.append(UInt8(n & 0xFF))
        } else {
            out.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((n >> shift) & 0xFF))
            }
        }
        out.append(payload)
        return out
    }

    static func encode(text: String, opcode: UInt8 = 0x1) -> Data {
        encode(Data(text.utf8), opcode: opcode)
    }

    // MARK: Reading

    struct Frame {
        let opcode: UInt8
        let payload: Data
        /// How many bytes of the buffer this frame consumed.
        let consumed: Int
    }

    /// Reads exactly one frame. `nil` means: not enough data buffered yet.
    static func decode(_ buffer: Data) -> Frame? {
        let bytes = [UInt8](buffer)
        guard bytes.count >= 2 else { return nil }

        let opcode = bytes[0] & 0x0F
        let masked = (bytes[1] & 0x80) != 0
        var length = Int(bytes[1] & 0x7F)
        var index = 2

        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = Int(bytes[2]) << 8 | Int(bytes[3])
            index = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            length = 0
            for i in 2..<10 { length = length << 8 | Int(bytes[i]) }
            index = 10
        }

        // Messages from the browser are tiny; anything larger is a mistake.
        guard length <= 1_000_000 else { return nil }

        var mask = [UInt8]()
        if masked {
            guard bytes.count >= index + 4 else { return nil }
            mask = Array(bytes[index..<index + 4])
            index += 4
        }

        guard bytes.count >= index + length else { return nil }
        var data = Array(bytes[index..<index + length])
        if masked {
            for i in 0..<data.count { data[i] ^= mask[i % 4] }
        }
        return Frame(opcode: opcode, payload: Data(data), consumed: index + length)
    }
}
