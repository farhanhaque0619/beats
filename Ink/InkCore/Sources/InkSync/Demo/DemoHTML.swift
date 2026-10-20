import Foundation

/// HTML (with a matching plain-text alternative) for the demo inbox's designed mail, written the
/// way real senders do it: table layout, inline CSS, a hidden preheader, no remote images.
enum DemoHTML {
    struct Rendered {
        var html: String
        var text: String
    }

    static let sans = "-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif"
    static let serif = "Georgia,'Iowan Old Style','Times New Roman',serif"

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for character in s {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(character)
            }
        }
        return out
    }

    /// Plain text to HTML blocks: blank lines separate paragraphs, lines starting with "• " become
    /// a list, single newlines become `<br>`.
    static func blocks(_ text: String, font: String, size: Int = 16, color: String = "#1d1d1f") -> String {
        var html = ""
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard !lines.isEmpty else { continue }
            if lines.allSatisfy({ $0.hasPrefix("• ") }) {
                html += "<ul style=\"margin:0 0 16px;padding-left:20px;font-family:\(font);font-size:\(size)px;line-height:1.55;color:\(color);\">"
                for line in lines { html += "<li style=\"margin:0 0 6px;\">\(escape(String(line.dropFirst(2))))</li>" }
                html += "</ul>"
            } else {
                html += "<p style=\"margin:0 0 16px;font-family:\(font);font-size:\(size)px;line-height:1.55;color:\(color);\">"
                html += lines.map(escape).joined(separator: "<br>")
                html += "</p>"
            }
        }
        return html
    }

    private static func document(title: String, preheader: String, background: String, body: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>\(escape(title))</title></head>
        <body style="margin:0;padding:0;background-color:\(background);">
        <div style="display:none;max-height:0;overflow:hidden;mso-hide:all;">\(escape(preheader))</div>
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:\(background);">
        <tr><td align="center" style="padding:24px 12px;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:600px;background-color:#ffffff;border-radius:14px;overflow:hidden;">
        \(body)
        </table>
        </td></tr></table>
        </body></html>
        """
    }

    private static func footer(_ lines: [String], unsubscribe: String?) -> String {
        var html = "<tr><td style=\"padding:20px 32px 28px;border-top:1px solid #ecebe8;font-family:\(sans);font-size:12px;line-height:1.6;color:#8a877f;\">"
        html += lines.map(escape).joined(separator: "<br>")
        if let unsubscribe {
            html += "<br><a href=\"\(escape(unsubscribe))\" style=\"color:#8a877f;text-decoration:underline;\">Unsubscribe</a> · <a href=\"\(escape(unsubscribe))?prefs=1\" style=\"color:#8a877f;text-decoration:underline;\">Email preferences</a>"
        }
        html += "</td></tr>"
        return html
    }

    private static func button(_ title: String, url: String, accent: String) -> String {
        "<table role=\"presentation\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\" style=\"margin:8px 0 20px;\"><tr><td style=\"border-radius:8px;background-color:\(accent);\"><a href=\"\(escape(url))\" style=\"display:inline-block;padding:12px 22px;font-family:\(sans);font-size:15px;font-weight:600;color:#ffffff;text-decoration:none;border-radius:8px;\">\(escape(title))</a></td></tr></table>"
    }

    // MARK: Templates

    struct Section {
        var heading: String
        var body: String
    }

    /// A long-form editorial newsletter.
    static func newsletter(brand: String, accent: String, background: String, kicker: String, title: String, preheader: String,
                           intro: String, heroImagePNG: Data?, heroAlt: String, sections: [Section], signoff: String,
                           footerLines: [String], unsubscribe: String) -> Rendered {
        var body = "<tr><td style=\"padding:28px 32px 4px;font-family:\(sans);font-size:12px;font-weight:700;letter-spacing:2px;text-transform:uppercase;color:\(accent);\">\(escape(brand)) · \(escape(kicker))</td></tr>"
        body += "<tr><td style=\"padding:6px 32px 12px;\"><h1 style=\"margin:0;font-family:\(serif);font-size:32px;line-height:1.18;font-weight:700;color:#1d1d1f;\">\(escape(title))</h1></td></tr>"
        if let heroImagePNG {
            body += "<tr><td style=\"padding:8px 32px 12px;\"><img src=\"data:image/png;base64,\(heroImagePNG.base64EncodedString())\" width=\"536\" alt=\"\(escape(heroAlt))\" style=\"display:block;width:100%;max-width:536px;height:auto;border:0;border-radius:10px;\"></td></tr>"
        }
        body += "<tr><td style=\"padding:12px 32px 0;\">\(blocks(intro, font: serif, size: 18))</td></tr>"
        for section in sections {
            body += "<tr><td style=\"padding:4px 32px 0;\"><h2 style=\"margin:12px 0 10px;font-family:\(sans);font-size:19px;line-height:1.3;color:#1d1d1f;\">\(escape(section.heading))</h2>\(blocks(section.body, font: serif, size: 17, color: "#2b2a28"))</td></tr>"
        }
        body += "<tr><td style=\"padding:4px 32px 16px;\">\(blocks(signoff, font: serif, size: 17, color: "#2b2a28"))</td></tr>"
        body += footer(footerLines, unsubscribe: unsubscribe)

        var text = "\(brand.uppercased()) · \(kicker)\n\n\(title)\n\n\(intro)\n\n"
        for section in sections { text += "\(section.heading.uppercased())\n\n\(section.body)\n\n" }
        text += "\(signoff)\n\n--\n\(footerLines.joined(separator: "\n"))\nUnsubscribe: \(unsubscribe)\n"
        return Rendered(html: document(title: title, preheader: preheader, background: background, body: body), text: text)
    }

    struct LineItem {
        var name: String
        var detail: String?
        var amount: String
    }

    /// An order receipt with line items and totals.
    static func receipt(brand: String, accent: String, title: String, preheader: String, intro: String, meta: [(String, String)],
                        items: [LineItem], totals: [(String, String)], note: String, footerLines: [String], unsubscribe: String?) -> Rendered {
        var body = "<tr><td style=\"padding:22px 32px;background-color:\(accent);font-family:\(sans);font-size:18px;font-weight:700;letter-spacing:0.5px;color:#ffffff;\">\(escape(brand))</td></tr>"
        body += "<tr><td style=\"padding:28px 32px 4px;\"><h1 style=\"margin:0 0 12px;font-family:\(sans);font-size:24px;line-height:1.25;color:#1d1d1f;\">\(escape(title))</h1>\(blocks(intro, font: sans, size: 15, color: "#3a3a3c"))</td></tr>"
        if !meta.isEmpty {
            body += "<tr><td style=\"padding:0 32px 8px;\"><table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"font-family:\(sans);font-size:13px;color:#6e6e73;\">"
            for (label, value) in meta {
                body += "<tr><td style=\"padding:3px 0;\">\(escape(label))</td><td align=\"right\" style=\"padding:3px 0;color:#1d1d1f;font-weight:600;\">\(escape(value))</td></tr>"
            }
            body += "</table></td></tr>"
        }
        body += "<tr><td style=\"padding:12px 32px;\"><table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"font-family:\(sans);font-size:15px;color:#1d1d1f;border-top:1px solid #e5e5ea;\">"
        for item in items {
            body += "<tr><td style=\"padding:14px 0;border-bottom:1px solid #f0f0f2;\"><div style=\"font-weight:600;\">\(escape(item.name))</div>"
            if let detail = item.detail { body += "<div style=\"font-size:13px;color:#6e6e73;margin-top:2px;\">\(escape(detail))</div>" }
            body += "</td><td align=\"right\" valign=\"top\" style=\"padding:14px 0;border-bottom:1px solid #f0f0f2;white-space:nowrap;\">\(escape(item.amount))</td></tr>"
        }
        for (index, total) in totals.enumerated() {
            let isLast = index == totals.count - 1
            let weight = isLast ? "font-weight:700;font-size:17px;" : "color:#6e6e73;"
            body += "<tr><td style=\"padding:8px 0 0;\(weight)\">\(escape(total.0))</td><td align=\"right\" style=\"padding:8px 0 0;\(weight)\">\(escape(total.1))</td></tr>"
        }
        body += "</table></td></tr>"
        body += "<tr><td style=\"padding:16px 32px 12px;\">\(blocks(note, font: sans, size: 14, color: "#3a3a3c"))</td></tr>"
        body += footer(footerLines, unsubscribe: unsubscribe)

        var text = "\(brand)\n\n\(title)\n\n\(intro)\n\n"
        for (label, value) in meta { text += "\(label): \(value)\n" }
        if !meta.isEmpty { text += "\n" }
        for item in items { text += "\(item.name)\(item.detail.map { " (\($0))" } ?? "")  \(item.amount)\n" }
        text += "\n"
        for (label, value) in totals { text += "\(label): \(value)\n" }
        text += "\n\(note)\n\n--\n\(footerLines.joined(separator: "\n"))\n"
        if let unsubscribe { text += "Unsubscribe: \(unsubscribe)\n" }
        return Rendered(html: document(title: title, preheader: preheader, background: "#f2f2f4", body: body), text: text)
    }

    struct DetailBlock {
        var heading: String
        var rows: [(String, String)]
    }

    /// A transactional "card": headline, intro, boxes of label/value rows, an optional button.
    static func card(brand: String, accent: String, title: String, preheader: String, intro: String, details: [DetailBlock],
                     action: (title: String, url: String)?, outro: String, footerLines: [String], unsubscribe: String?) -> Rendered {
        var body = "<tr><td style=\"padding:24px 32px 0;font-family:\(sans);font-size:15px;font-weight:800;letter-spacing:0.4px;color:\(accent);\">\(escape(brand))</td></tr>"
        body += "<tr><td style=\"padding:14px 32px 4px;\"><h1 style=\"margin:0 0 12px;font-family:\(sans);font-size:24px;line-height:1.25;color:#1d1d1f;\">\(escape(title))</h1>\(blocks(intro, font: sans, size: 15, color: "#3a3a3c"))</td></tr>"
        for detail in details {
            body += "<tr><td style=\"padding:0 32px 14px;\"><table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"background-color:#f5f6f8;border-radius:10px;font-family:\(sans);\">"
            body += "<tr><td colspan=\"2\" style=\"padding:14px 16px 6px;font-size:12px;font-weight:700;letter-spacing:1px;text-transform:uppercase;color:\(accent);\">\(escape(detail.heading))</td></tr>"
            for (label, value) in detail.rows {
                body += "<tr><td valign=\"top\" style=\"padding:5px 16px;font-size:14px;color:#6e6e73;width:38%;\">\(escape(label))</td><td valign=\"top\" style=\"padding:5px 16px;font-size:14px;color:#1d1d1f;font-weight:600;\">\(escape(value))</td></tr>"
            }
            body += "<tr><td colspan=\"2\" style=\"height:10px;line-height:10px;font-size:0;\">&nbsp;</td></tr></table></td></tr>"
        }
        body += "<tr><td style=\"padding:4px 32px 8px;\">"
        if let action { body += button(action.title, url: action.url, accent: accent) }
        body += blocks(outro, font: sans, size: 15, color: "#3a3a3c")
        body += "</td></tr>"
        body += footer(footerLines, unsubscribe: unsubscribe)

        var text = "\(brand)\n\n\(title)\n\n\(intro)\n\n"
        for detail in details {
            text += "\(detail.heading.uppercased())\n"
            for (label, value) in detail.rows { text += "\(label): \(value)\n" }
            text += "\n"
        }
        if let action { text += "\(action.title): \(action.url)\n\n" }
        text += "\(outro)\n\n--\n\(footerLines.joined(separator: "\n"))\n"
        if let unsubscribe { text += "Unsubscribe: \(unsubscribe)\n" }
        return Rendered(html: document(title: title, preheader: preheader, background: "#eef0f3", body: body), text: text)
    }
}
