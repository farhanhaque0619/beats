import Foundation

/// Modified UTF-7, the encoding IMAP uses for non-ASCII mailbox names (RFC 3501 §5.1.3).
///
/// Printable ASCII stands for itself, except `&`, which is written `&-`. Every other run of
/// characters is written as `&`, the UTF-16BE code units in base64 (with `,` in place of `/`
/// and no padding), then `-`:
///
///     ModifiedUTF7.encode("~peter/mail/台北/日本語")   // "~peter/mail/&U,BTFw-/&ZeVnLIqe-"
///     ModifiedUTF7.decode("Entw&APw-rfe")             // "Entwürfe"
///
/// Decoding is lenient: malformed shift sequences are kept as-is instead of failing, so a
/// broken server never makes a folder disappear.
public enum ModifiedUTF7 {
    private static let alphabet: [UInt8] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+,".utf8)
    private static let reverse: [UInt8] = {
        var table = [UInt8](repeating: 0xFF, count: 256)
        for (index, char) in alphabet.enumerated() { table[Int(char)] = UInt8(index) }
        return table
    }()

    private static let ampersand = UInt8(ascii: "&")
    private static let dash = UInt8(ascii: "-")

    /// Encodes a Unicode mailbox name for the wire.
    public static func encode(_ string: String) -> String {
        var output: [UInt8] = []
        output.reserveCapacity(string.utf8.count + 8)
        var pending: [UInt16] = []

        func flush() {
            guard !pending.isEmpty else { return }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(pending.count * 2)
            for unit in pending {
                bytes.append(UInt8(truncatingIfNeeded: unit >> 8))
                bytes.append(UInt8(truncatingIfNeeded: unit))
            }
            output.append(ampersand)
            var index = 0
            while index + 3 <= bytes.count {
                let chunk = UInt32(bytes[index]) << 16 | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2])
                output.append(alphabet[Int(chunk >> 18 & 0x3F)])
                output.append(alphabet[Int(chunk >> 12 & 0x3F)])
                output.append(alphabet[Int(chunk >> 6 & 0x3F)])
                output.append(alphabet[Int(chunk & 0x3F)])
                index += 3
            }
            switch bytes.count - index {
            case 1:
                let chunk = UInt32(bytes[index]) << 16
                output.append(alphabet[Int(chunk >> 18 & 0x3F)])
                output.append(alphabet[Int(chunk >> 12 & 0x3F)])
            case 2:
                let chunk = UInt32(bytes[index]) << 16 | UInt32(bytes[index + 1]) << 8
                output.append(alphabet[Int(chunk >> 18 & 0x3F)])
                output.append(alphabet[Int(chunk >> 12 & 0x3F)])
                output.append(alphabet[Int(chunk >> 6 & 0x3F)])
            default:
                break
            }
            output.append(dash)
            pending.removeAll(keepingCapacity: true)
        }

        for scalar in string.unicodeScalars {
            let value = scalar.value
            if value >= 0x20 && value <= 0x7E {
                flush()
                output.append(UInt8(value))
                if value == 0x26 { output.append(dash) }
            } else if value < 0x10000 {
                pending.append(UInt16(value))
            } else {
                let offset = value - 0x10000
                pending.append(UInt16(0xD800 + (offset >> 10)))
                pending.append(UInt16(0xDC00 + (offset & 0x3FF)))
            }
        }
        flush()
        return String(decoding: output, as: UTF8.self)
    }

    /// Decodes a wire mailbox name to Unicode. Text outside `&…-` sequences (including any
    /// raw UTF-8 a non-conforming server sends) passes through unchanged.
    public static func decode(_ string: String) -> String {
        let bytes = Array(string.utf8)
        guard bytes.contains(ampersand) else { return string }
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count + 16)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            guard byte == ampersand else {
                output.append(byte)
                index += 1
                continue
            }
            var end = index + 1
            while end < bytes.count, bytes[end] != dash, reverse[Int(bytes[end])] != 0xFF { end += 1 }
            guard end < bytes.count, bytes[end] == dash else {
                // No terminating "-" (or an illegal character inside): keep the "&" literally.
                output.append(byte)
                index += 1
                continue
            }
            if end == index + 1 {
                output.append(ampersand)  // "&-"
                index = end + 1
                continue
            }
            if let decoded = decodeBase64UTF16(bytes[(index + 1)..<end]) {
                output.append(contentsOf: decoded.utf8)
            } else {
                output.append(contentsOf: bytes[index...end])
            }
            index = end + 1
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Decodes the modified-base64 body of one shift sequence; nil when it isn't whole UTF-16.
    private static func decodeBase64UTF16(_ chars: ArraySlice<UInt8>) -> String? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(chars.count * 3 / 4 + 1)
        var accumulator: UInt32 = 0
        var bits = 0
        for char in chars {
            let value = reverse[Int(char)]
            guard value != 0xFF else { return nil }
            accumulator = accumulator << 6 | UInt32(value)
            bits += 6
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8(truncatingIfNeeded: accumulator >> UInt32(bits)))
                accumulator &= (1 << UInt32(bits)) - 1
            }
        }
        // Leftover bits must be padding (fewer than 6, all zero) and the bytes whole UTF-16 units.
        guard bits < 6, accumulator == 0, !bytes.isEmpty, bytes.count % 2 == 0 else { return nil }
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var position = 0
        while position + 1 < bytes.count {
            units.append(UInt16(bytes[position]) << 8 | UInt16(bytes[position + 1]))
            position += 2
        }
        return String(decoding: units, as: UTF16.self)
    }
}
