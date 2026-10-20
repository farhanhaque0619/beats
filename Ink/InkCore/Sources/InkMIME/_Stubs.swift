// TEMPORARY: signatures from ARCHITECTURE.md so the app can be compiled on CI before the real
// InkMIME lands. The real module replaces this directory.
import Foundation
import InkModel

public enum EmailHTMLDocument {
    public struct Options: Sendable {
        public var dark: Bool
        public var allowRemoteContent: Bool
        public var accentHex: String
        public var fontFamily: String
        public var fontSizePx: Int
        public var collapseQuotes: Bool
        public init(dark: Bool, allowRemoteContent: Bool, accentHex: String, fontFamily: String, fontSizePx: Int, collapseQuotes: Bool) {
            self.dark = dark; self.allowRemoteContent = allowRemoteContent; self.accentHex = accentHex
            self.fontFamily = fontFamily; self.fontSizePx = fontSizePx; self.collapseQuotes = collapseQuotes
        }
    }
    public static func build(html: String?, plainText: String?, options: Options) -> String {
        "<html><body>\(html ?? plainText ?? "")</body></html>"
    }
    public static func isDesigned(_ html: String) -> Bool { false }
    public static func countRemoteImages(_ html: String) -> Int { 0 }
    public static func countTrackingPixels(_ html: String) -> Int { 0 }
}

public enum AddressParser {
    public static func parseList(_ s: String) -> [EmailAddress] {
        s.split(separator: ",").map { EmailAddress(address: String($0)) }
    }
    public static func parse(_ s: String) -> EmailAddress? { parseList(s).first }
}
