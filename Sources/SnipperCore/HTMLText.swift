import Foundation

/// Small, dependency-free helpers for pulling text out of HTML.
public enum HTMLText {
    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "mdash": "—", "ndash": "–", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "laquo": "«", "raquo": "»", "middot": "·", "bull": "•", "copy": "©", "reg": "®", "trade": "™",
        "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "times": "×", "divide": "÷", "deg": "°",
        "para": "¶", "sect": "§", "shy": "\u{00AD}", "zwj": "\u{200D}", "zwnj": "\u{200C}",
    ]

    /// Decodes named and numeric character references (`&amp;`, `&#39;`, `&#x1F600;`).
    public static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            guard ch == "&", let semicolon = s[i...].prefix(12).firstIndex(of: ";") else {
                out.append(ch)
                i = s.index(after: i)
                continue
            }
            let name = s[s.index(after: i)..<semicolon]
            if let decoded = decodeReference(name) {
                out += decoded
                i = s.index(after: semicolon)
            } else {
                out.append(ch)
                i = s.index(after: i)
            }
        }
        return out
    }

    private static func decodeReference(_ name: Substring) -> String? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
        return namedEntities[String(name)]
    }

    /// Converts an HTML fragment to plain text, keeping line breaks.
    public static func plainText(fromHTML html: String) -> String {
        var s = html
        s = replace(s, #"<br\s*/?>"#, "\n")
        s = replace(s, #"</(p|div|li|h[1-6]|blockquote)>"#, "\n")
        s = replace(s, #"<(script|style)[^>]*>[\s\S]*?</\1>"#, "")
        s = replace(s, #"<[^>]+>"#, "")
        s = decodeEntities(s)
        s = s.replacingOccurrences(of: "\u{00A0}", with: " ")
        s = replace(s, #"[ \t]+\n"#, "\n")
        s = replace(s, #"\n{3,}"#, "\n\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func replace(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return s }
        return regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    /// All matches of `pattern`, each as its capture groups (index 0 is the whole match).
    static func matches(_ s: String, _ pattern: String, options: NSRegularExpression.Options = [.caseInsensitive]) -> [[String?]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        return regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { match in
            (0..<match.numberOfRanges).map { idx in
                Range(match.range(at: idx), in: s).map { String(s[$0]) }
            }
        }
    }

    /// Attributes of a start tag, lowercased names → decoded values.
    static func attributes(ofTag tag: String) -> [String: String] {
        var result: [String: String] = [:]
        for m in matches(tag, #"([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#) {
            guard let name = m[1]?.lowercased() else { continue }
            let value = m[2] ?? m[3] ?? m[4] ?? ""
            if result[name] == nil { result[name] = decodeEntities(value) }
        }
        return result
    }
}

/// Reads Open Graph and standard metadata from a web page.
public enum LinkMetadataParser {
    public struct Result: Equatable, Sendable {
        public var title: String?
        public var info: LinkInfo
    }

    public static func parse(html fullHTML: String, pageURL: URL) -> Result {
        // Metadata lives in <head>; skip the rest of large pages.
        let html: String
        if let headEnd = fullHTML.range(of: "</head>", options: .caseInsensitive) {
            html = String(fullHTML[..<headEnd.upperBound])
        } else {
            html = String(fullHTML.prefix(400_000))
        }

        var meta: [String: String] = [:]
        for m in HTMLText.matches(html, #"<meta\b[^>]*>"#) {
            guard let tag = m[0] else { continue }
            let attrs = HTMLText.attributes(ofTag: tag)
            guard let key = (attrs["property"] ?? attrs["name"] ?? attrs["itemprop"])?.lowercased(),
                  let content = attrs["content"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty, meta[key] == nil
            else { continue }
            meta[key] = content
        }

        let titleTag = HTMLText.matches(html, #"<title[^>]*>([\s\S]*?)</title>"#).first?[1]
            .map { HTMLText.decodeEntities($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        var icon: String?
        var bestIconScore = -1
        for m in HTMLText.matches(html, #"<link\b[^>]*>"#) {
            guard let tag = m[0] else { continue }
            let attrs = HTMLText.attributes(ofTag: tag)
            guard let rel = attrs["rel"]?.lowercased(), rel.contains("icon"), let href = attrs["href"] else { continue }
            // Prefer touch icons (large), then explicit icons, then anything else.
            let score = rel.contains("apple-touch-icon") ? 3 : (rel == "icon" ? 2 : 1)
            if score > bestIconScore {
                bestIconScore = score
                icon = href
            }
        }

        func absolute(_ s: String?) -> String? {
            guard let s, !s.isEmpty else { return nil }
            return URL(string: s, relativeTo: pageURL)?.absoluteURL.absoluteString
        }

        let title = meta["og:title"] ?? meta["twitter:title"] ?? titleTag
        let info = LinkInfo(
            url: absolute(meta["og:url"]) ?? pageURL.absoluteString,
            title: title,
            summary: meta["og:description"] ?? meta["twitter:description"] ?? meta["description"],
            siteName: meta["og:site_name"] ?? meta["application-name"],
            imageURL: absolute(meta["og:image:secure_url"] ?? meta["og:image"] ?? meta["twitter:image"] ?? meta["twitter:image:src"]),
            faviconURL: absolute(icon) ?? pageURL.host.map { "\(pageURL.scheme ?? "https")://\($0)/favicon.ico" }
        )
        return Result(title: title, info: info)
    }
}
