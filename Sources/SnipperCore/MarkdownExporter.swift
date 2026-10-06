import Foundation

/// Renders snips as Markdown files with YAML front matter (Obsidian-friendly).
public enum MarkdownExporter {
    public static func markdown(for snip: Snip, mediaFolder: String = "media") -> String {
        var front: [(String, String)] = [
            ("id", snip.id.uuidString),
            ("kind", snip.kind.rawValue),
            ("created", DateParsing.isoString(snip.createdAt)),
            ("saved", DateParsing.isoString(snip.savedAt)),
        ]
        if let url = snip.url { front.append(("source", url)) }
        if let author = snip.author { front.append(("author", "@\(author.handle)")) }
        if snip.isFavorite { front.append(("favorite", "true")) }

        var lines = ["---"]
        for (key, value) in front { lines.append("\(key): \(yamlString(value))") }
        if !snip.tags.isEmpty {
            lines.append("tags: [\(snip.tags.map(yamlString).joined(separator: ", "))]")
        }
        lines.append("---")
        lines.append("")
        lines.append("# \(snip.displayTitle.replacingOccurrences(of: "\n", with: " "))")
        lines.append("")

        if let author = snip.author, snip.kind == .tweet {
            lines.append("**\(author.name)** [@\(author.handle)](https://x.com/\(author.handle)) · \(shortDate(snip.createdAt))")
            lines.append("")
        }
        if !snip.body.isEmpty {
            if snip.kind == .tweet || snip.kind == .text {
                lines.append(contentsOf: snip.body.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> \($0)" })
            } else {
                lines.append(snip.body)
            }
            lines.append("")
        }
        if let quoted = snip.tweet?.quoted {
            let who = quoted.author.map { "@\($0.handle)" } ?? "Quoted post"
            lines.append("> **\(who)**")
            lines.append(contentsOf: quoted.text.components(separatedBy: "\n").map { "> \($0)" })
            if let url = quoted.url { lines.append("> [Open quoted post](\(url))") }
            lines.append("")
        }
        if let link = snip.link ?? snip.tweet?.card, let summary = link.summary, !summary.isEmpty, snip.kind == .link || snip.kind == .tweet {
            lines.append("*\(summary)*")
            lines.append("")
        }
        for media in snip.media {
            if let file = media.localFile {
                lines.append("![\(media.alt ?? "")](\(mediaFolder)/\(file))")
            } else if let remote = media.remoteURL {
                lines.append("![\(media.alt ?? "")](\(remote))")
            }
        }
        if !snip.media.isEmpty { lines.append("") }
        if let ocr = snip.ocrText, !ocr.isEmpty {
            lines.append("<details><summary>Text in image</summary>")
            lines.append("")
            lines.append(ocr)
            lines.append("")
            lines.append("</details>")
            lines.append("")
        }
        if let url = snip.url {
            lines.append("[Open original](\(url))")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// "2024-03-01 Why glass works.md", unique per snip and safe for any file system.
    public static func fileName(for snip: Snip) -> String {
        let date = String(DateParsing.isoString(snip.savedAt).prefix(10))
        let title = snip.displayTitle
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t#^[]"))
            .joined(separator: " ")
            .split(separator: " ")
            .joined(separator: " ")
        let short = String(title.prefix(60)).trimmingCharacters(in: .whitespaces)
        let suffix = snip.id.uuidString.prefix(4).lowercased()
        return "\(date) \(short.isEmpty ? snip.kind.label : short) \(suffix).md"
    }

    static func yamlString(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    static func shortDate(_ d: Date) -> String {
        String(DateParsing.isoString(d).prefix(10))
    }
}
