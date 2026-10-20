import Foundation

/// Domain name checks and IDNA (Punycode) conversion for building lookup URLs safely.
enum DomainName {
    /// The ASCII (`xn--`) form of `domain`, lowercased and without a trailing dot, or nil when it
    /// isn't a plausible host name. Anything that could change the meaning of a URL (`/`, `?`,
    /// `#`, `@`, `:`, spaces, controls) is rejected.
    static func ascii(_ domain: String) -> String? {
        var value = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix(".") { value.removeLast() }
        guard !value.isEmpty else { return nil }
        let converted: String
        if value.unicodeScalars.allSatisfy({ $0.isASCII }) {
            converted = value.lowercased()
        } else {
            guard let idna = Punycode.idnaDomain(value) else { return nil }
            converted = idna
        }
        guard converted.utf8.count <= 253 else { return nil }
        let labels = converted.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return nil }
        for label in labels {
            guard !label.isEmpty, label.utf8.count <= 63, label.first != "-", label.last != "-" else { return nil }
            for byte in label.utf8 {
                let ok = (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39) || byte == 0x2D || byte == 0x5F
                guard ok else { return nil }
            }
        }
        return converted
    }

    /// The registrable-looking base of a host (`mx01.ionos.de` → `ionos.de`,
    /// `mail.example.co.uk` → `example.co.uk`). A heuristic, not the Public Suffix List.
    static func baseDomain(of host: String) -> String {
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let secondLevel = labels[labels.count - 2]
        let topLevel = labels[labels.count - 1]
        let shortSecondLevels: Set<String> = ["co", "com", "net", "org", "gov", "ac", "edu", "ne", "or", "go"]
        let keep = (topLevel.count == 2 && shortSecondLevels.contains(secondLevel)) ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }
}

/// RFC 3492 Punycode, enough for turning internationalised domain labels into `xn--` labels.
enum Punycode {
    private static let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700, initialBias = 72, initialN = 128

    /// `bücher.example` → `xn--bcher-kva.example`. Labels are NFC-normalised and lowercased first.
    static func idnaDomain(_ domain: String) -> String? {
        let normalized = domain.precomposedStringWithCanonicalMapping.lowercased()
        let separators: Set<Character> = [".", "\u{3002}", "\u{FF0E}", "\u{FF61}"]
        var labels: [String] = []
        var current = ""
        for character in normalized {
            if separators.contains(character) { labels.append(current); current = "" } else { current.append(character) }
        }
        labels.append(current)
        var output: [String] = []
        for label in labels {
            if label.unicodeScalars.allSatisfy({ $0.isASCII }) {
                output.append(label)
            } else {
                guard let encoded = encode(label) else { return nil }
                let full = "xn--" + encoded
                guard full.utf8.count <= 63 else { return nil }
                output.append(full)
            }
        }
        return output.joined(separator: ".")
    }

    /// Encodes one label (without the `xn--` prefix).
    static func encode(_ input: String) -> String? {
        let codePoints = input.unicodeScalars.map { Int($0.value) }
        var output: [UInt8] = codePoints.filter { $0 < 0x80 }.map { UInt8($0) }
        let basicCount = output.count
        var handled = basicCount
        if basicCount > 0 { output.append(UInt8(ascii: "-")) }
        var n = initialN
        var delta = 0
        var bias = initialBias
        while handled < codePoints.count {
            guard let m = codePoints.filter({ $0 >= n }).min() else { return nil }
            let (product, overflow) = (m - n).multipliedReportingOverflow(by: handled + 1)
            guard !overflow else { return nil }
            delta += product
            n = m
            for c in codePoints {
                if c < n { delta += 1 }
                if c == n {
                    var q = delta
                    var k = base
                    while true {
                        let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                        if q < t { break }
                        output.append(digit(t + (q - t) % (base - t)))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    output.append(digit(q))
                    bias = adapt(delta, numPoints: handled + 1, firstTime: handled == basicCount)
                    delta = 0
                    handled += 1
                }
            }
            delta += 1
            n += 1
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func digit(_ value: Int) -> UInt8 {
        value < 26 ? UInt8(value + 97) : UInt8(value - 26 + 48)
    }

    private static func adapt(_ delta: Int, numPoints: Int, firstTime: Bool) -> Int {
        var delta = firstTime ? delta / damp : delta / 2
        delta += delta / numPoints
        var k = 0
        while delta > ((base - tMin) * tMax) / 2 {
            delta /= base - tMin
            k += base
        }
        return k + (base - tMin + 1) * delta / (delta + skew)
    }
}
