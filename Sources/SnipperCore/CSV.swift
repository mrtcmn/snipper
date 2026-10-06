import Foundation

/// RFC 4180 CSV parsing: quoted fields, escaped quotes ("") and line breaks inside quotes.
public enum CSV {
    public static func parse(_ text: String, separator: Character? = nil) -> [[String]] {
        let sep = separator ?? detectSeparator(text)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character? = nil

        func endField() {
            row.append(field)
            field = ""
        }
        func endRow() {
            endField()
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }

        while let ch = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if ch == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            pending = next
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(ch)
                }
            } else if ch == "\"" && field.isEmpty {
                inQuotes = true
            } else if ch == sep {
                endField()
            } else if ch == "\n" || ch == "\r\n" || ch == "\r" {
                endRow()
            } else {
                field.append(ch)
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    /// Rows as dictionaries keyed by the lowercased header row.
    public static func records(_ text: String) -> [[String: String]] {
        let rows = parse(text)
        guard let header = rows.first else { return [] }
        let keys = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return rows.dropFirst().map { values in
            var record: [String: String] = [:]
            for (i, key) in keys.enumerated() where i < values.count && !key.isEmpty {
                record[key] = values[i]
            }
            return record
        }
    }

    private static func detectSeparator(_ text: String) -> Character {
        let firstLine = text.prefix { $0 != "\n" && $0 != "\r\n" }
        let candidates: [Character] = [",", ";", "\t"]
        return candidates.max { a, b in
            firstLine.filter { $0 == a }.count < firstLine.filter { $0 == b }.count
        } ?? ","
    }
}
