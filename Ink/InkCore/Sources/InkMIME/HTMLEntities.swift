import Foundation

/// Named character references: all of HTML 4.01 plus the HTML5 names that show up in mail.
enum HTMLEntities {
    /// Latin-1 names for U+00A0…U+00FF, in order. These may also appear without a semicolon.
    private static let latin1Names = [
        "nbsp", "iexcl", "cent", "pound", "curren", "yen", "brvbar", "sect", "uml", "copy", "ordf", "laquo", "not", "shy", "reg", "macr",
        "deg", "plusmn", "sup2", "sup3", "acute", "micro", "para", "middot", "cedil", "sup1", "ordm", "raquo", "frac14", "frac12", "frac34", "iquest",
        "Agrave", "Aacute", "Acirc", "Atilde", "Auml", "Aring", "AElig", "Ccedil", "Egrave", "Eacute", "Ecirc", "Euml", "Igrave", "Iacute", "Icirc", "Iuml",
        "ETH", "Ntilde", "Ograve", "Oacute", "Ocirc", "Otilde", "Ouml", "times", "Oslash", "Ugrave", "Uacute", "Ucirc", "Uuml", "Yacute", "THORN", "szlig",
        "agrave", "aacute", "acirc", "atilde", "auml", "aring", "aelig", "ccedil", "egrave", "eacute", "ecirc", "euml", "igrave", "iacute", "icirc", "iuml",
        "eth", "ntilde", "ograve", "oacute", "ocirc", "otilde", "ouml", "divide", "oslash", "ugrave", "uacute", "ucirc", "uuml", "yacute", "thorn", "yuml",
    ]

    private static let others: [String: UInt32] = [
        // HTML 4 special
        "quot": 34, "amp": 38, "lt": 60, "gt": 62, "apos": 39,
        "OElig": 338, "oelig": 339, "Scaron": 352, "scaron": 353, "Yuml": 376, "circ": 710, "tilde": 732,
        "ensp": 8194, "emsp": 8195, "thinsp": 8201, "zwnj": 8204, "zwj": 8205, "lrm": 8206, "rlm": 8207,
        "ndash": 8211, "mdash": 8212, "lsquo": 8216, "rsquo": 8217, "sbquo": 8218, "ldquo": 8220, "rdquo": 8221, "bdquo": 8222,
        "dagger": 8224, "Dagger": 8225, "permil": 8240, "lsaquo": 8249, "rsaquo": 8250, "euro": 8364,
        // HTML 4 symbols and Greek
        "fnof": 402,
        "Alpha": 913, "Beta": 914, "Gamma": 915, "Delta": 916, "Epsilon": 917, "Zeta": 918, "Eta": 919, "Theta": 920, "Iota": 921,
        "Kappa": 922, "Lambda": 923, "Mu": 924, "Nu": 925, "Xi": 926, "Omicron": 927, "Pi": 928, "Rho": 929, "Sigma": 931, "Tau": 932,
        "Upsilon": 933, "Phi": 934, "Chi": 935, "Psi": 936, "Omega": 937,
        "alpha": 945, "beta": 946, "gamma": 947, "delta": 948, "epsilon": 949, "zeta": 950, "eta": 951, "theta": 952, "iota": 953,
        "kappa": 954, "lambda": 955, "mu": 956, "nu": 957, "xi": 958, "omicron": 959, "pi": 960, "rho": 961, "sigmaf": 962, "sigma": 963,
        "tau": 964, "upsilon": 965, "phi": 966, "chi": 967, "psi": 968, "omega": 969, "thetasym": 977, "upsih": 978, "piv": 982,
        "bull": 8226, "hellip": 8230, "prime": 8242, "Prime": 8243, "oline": 8254, "frasl": 8260, "weierp": 8472, "image": 8465,
        "real": 8476, "trade": 8482, "alefsym": 8501, "larr": 8592, "uarr": 8593, "rarr": 8594, "darr": 8595, "harr": 8596, "crarr": 8629,
        "lArr": 8656, "uArr": 8657, "rArr": 8658, "dArr": 8659, "hArr": 8660, "forall": 8704, "part": 8706, "exist": 8707, "empty": 8709,
        "nabla": 8711, "isin": 8712, "notin": 8713, "ni": 8715, "prod": 8719, "sum": 8721, "minus": 8722, "lowast": 8727, "radic": 8730,
        "prop": 8733, "infin": 8734, "ang": 8736, "and": 8743, "or": 8744, "cap": 8745, "cup": 8746, "int": 8747, "there4": 8756,
        "sim": 8764, "cong": 8773, "asymp": 8776, "ne": 8800, "equiv": 8801, "le": 8804, "ge": 8805, "sub": 8834, "sup": 8835,
        "nsub": 8836, "sube": 8838, "supe": 8839, "oplus": 8853, "otimes": 8855, "perp": 8869, "sdot": 8901, "lceil": 8968,
        "rceil": 8969, "lfloor": 8970, "rfloor": 8971, "lang": 10216, "rang": 10217, "loz": 9674, "spades": 9824, "clubs": 9827,
        "hearts": 9829, "diams": 9830,
        // HTML5 names common in newsletters and generated mail
        "Tab": 9, "NewLine": 10, "excl": 33, "num": 35, "dollar": 36, "percnt": 37, "lpar": 40, "rpar": 41, "ast": 42, "plus": 43,
        "comma": 44, "period": 46, "sol": 47, "colon": 58, "semi": 59, "equals": 61, "quest": 63, "commat": 64, "lsqb": 91,
        "lbrack": 91, "bsol": 92, "rsqb": 93, "rbrack": 93, "Hat": 94, "lowbar": 95, "grave": 96, "lcub": 123, "lbrace": 123,
        "verbar": 124, "vert": 124, "rcub": 125, "rbrace": 125, "AMP": 38, "LT": 60, "GT": 62, "QUOT": 34, "COPY": 169, "REG": 174,
        "TRADE": 8482, "hyphen": 8208, "dash": 8208, "horbar": 8213, "nbhy": 8209, "numsp": 8199, "puncsp": 8200, "hairsp": 8202,
        "emsp13": 8196, "emsp14": 8197, "ThinSpace": 8201, "MediumSpace": 8287, "NoBreak": 8288, "ZeroWidthSpace": 8203,
        "NonBreakingSpace": 160, "bullet": 8226, "nldr": 8229, "mldr": 8230, "centerdot": 183, "rsquor": 8217, "lsquor": 8218,
        "rdquor": 8221, "ldquor": 8222, "half": 189, "frac13": 8531, "frac23": 8532, "frac15": 8533, "frac25": 8534, "frac35": 8535,
        "frac45": 8536, "frac16": 8537, "frac56": 8538, "frac18": 8539, "frac38": 8540, "frac58": 8541, "frac78": 8542,
        "check": 10003, "checkmark": 10003, "cross": 10007, "star": 9734, "starf": 9733, "bigstar": 9733, "phone": 9742,
        "female": 9792, "male": 9794, "sharp": 9839, "flat": 9837, "natural": 9838, "copysr": 8471, "rightarrow": 8594,
        "leftarrow": 8592, "uparrow": 8593, "downarrow": 8595, "RightArrow": 8594, "LeftArrow": 8592, "dot": 729, "die": 168,
        "Dot": 168, "laquo": 171, "raquo": 187, "inodot": 305, "imath": 305, "ell": 8467, "angle": 8736, "infintie": 10717,
        "squ": 9633, "square": 9633, "squf": 9642, "blacksquare": 9642, "utri": 9653, "dtri": 9663, "rtri": 9657, "ltri": 9667,
        "utrif": 9652, "dtrif": 9662, "rtrif": 9656, "ltrif": 9666, "cir": 9675, "lozf": 10731, "spadesuit": 9824,
        "clubsuit": 9827, "heartsuit": 9829, "diamondsuit": 9830, "sext": 10038, "malt": 10016, "maltese": 10016, "ohm": 937,
        "mho": 8487, "angst": 197, "numero": 8470, "incare": 8453, "planck": 8463, "hbar": 8463, "plankv": 8463,
        "tprime": 8244, "bprime": 8245, "backprime": 8245, "caret": 8257, "hybull": 8259, "Ccaron": 268, "ccaron": 269,
        "Zcaron": 381, "zcaron": 382, "Rcaron": 344, "rcaron": 345, "Ecaron": 282, "ecaron": 283, "Lstrok": 321, "lstrok": 322,
        "Nacute": 323, "nacute": 324, "Sacute": 346, "sacute": 347, "Zacute": 377, "zacute": 378, "Zdot": 379, "zdot": 380,
        "Aogon": 260, "aogon": 261, "Eogon": 280, "eogon": 281, "Cacute": 262, "cacute": 263, "Gbreve": 286, "gbreve": 287,
        "Idot": 304, "Scedil": 350, "scedil": 351, "Uring": 366, "uring": 367, "Ncaron": 327, "ncaron": 328, "Tcaron": 356,
        "tcaron": 357, "Dcaron": 270, "dcaron": 271, "Amacr": 256, "amacr": 257, "Emacr": 274, "emacr": 275,
    ]

    /// Every supported name → code point.
    static let table: [String: UInt32] = {
        var t = others
        for (i, name) in latin1Names.enumerated() { t[name] = UInt32(0xA0 + i) }
        return t
    }()

    /// Names that browsers decode even without a trailing semicolon (HTML5 "legacy" entities).
    static let legacy: Set<String> = {
        var s = Set(latin1Names)
        s.formUnion(["amp", "lt", "gt", "quot", "AMP", "LT", "GT", "QUOT", "COPY", "REG"])
        return s
    }()

    static let longestName = 16

    /// Decodes the character reference starting at `b[start]` (which is "&").
    /// Returns the scalar and the index just past the reference, or nil when it isn't one.
    /// In attribute values a legacy name followed by "=" or an alphanumeric isn't decoded (URLs).
    static func decode(_ b: [UInt8], at start: Int, end: Int, inAttribute: Bool = false) -> (Unicode.Scalar, Int)? {
        var i = start + 1
        guard i < end else { return nil }
        if b[i] == ASCII.hash {
            i += 1
            var hex = false
            if i < end && (b[i] == 0x78 || b[i] == 0x58) { hex = true; i += 1 }
            let digitsStart = i
            var value: UInt32 = 0
            var overflow = false
            while i < end {
                let c = b[i]
                let d: UInt32
                if hex, let h = hexValue(c) { d = UInt32(h) } else if !hex, isASCIIDigit(c) { d = UInt32(c - 0x30) } else { break }
                if value > 0x10FFFF { overflow = true } else { value = value * (hex ? 16 : 10) + d }
                i += 1
            }
            guard i > digitsStart else { return nil }
            if i < end && b[i] == ASCII.semicolon { i += 1 }
            return (numericScalar(value, overflow: overflow), i)
        }
        let nameStart = i
        while i < end && i - nameStart < longestName + 1 && (isASCIILetter(b[i]) || isASCIIDigit(b[i])) { i += 1 }
        guard i > nameStart else { return nil }
        let name = String(decoding: b[nameStart..<i], as: UTF8.self)
        if i < end && b[i] == ASCII.semicolon, let v = table[name], let scalar = Unicode.Scalar(v) {
            return (scalar, i + 1)
        }
        // No semicolon: longest legacy prefix ("&copy2026", "&nbsp ").
        var len = name.count
        while len >= 2 {
            let prefix = String(name.prefix(len))
            if legacy.contains(prefix), let v = table[prefix], let scalar = Unicode.Scalar(v) {
                let after = nameStart + len
                if inAttribute && after < end && (b[after] == ASCII.equals || isASCIILetter(b[after]) || isASCIIDigit(b[after])) {
                    return nil
                }
                return (scalar, after)
            }
            len -= 1
        }
        return nil
    }

    static func numericScalar(_ value: UInt32, overflow: Bool) -> Unicode.Scalar {
        if overflow || value == 0 || value > 0x10FFFF { return "\u{FFFD}" }
        if (0x80...0x9F).contains(value) {
            let mapped = SingleByteTables.windows1252High[Int(value) - 0x80]
            return Unicode.Scalar(UInt32(mapped)) ?? "\u{FFFD}"
        }
        return Unicode.Scalar(value) ?? "\u{FFFD}"
    }
}
