import Foundation

/// Parses the date formats found in post exports and web pages.
public enum DateParsing {
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f
    }

    /// "Wed Oct 10 20:19:24 +0000 2018", the format of X's REST and GraphQL APIs.
    private static let twitterLegacy = formatter("EEE MMM dd HH:mm:ss Z yyyy")
    private static let sqlLike = formatter("yyyy-MM-dd HH:mm:ss")
    private static let dayOnly = formatter("yyyy-MM-dd")
    /// "March 1, 2024", as printed in oEmbed markup.
    private static let longEnglish = formatter("MMMM d, yyyy")

    public static func parse(_ raw: String) -> Date? {
        let string = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty else { return nil }

        if string.allSatisfy({ $0.isNumber || $0 == "." }), let number = Double(string) {
            return fromEpoch(number)
        }
        if let d = isoFractional.date(from: string) ?? iso.date(from: string) { return d }
        for f in [twitterLegacy, sqlLike, dayOnly, longEnglish] {
            if let d = f.date(from: string) { return d }
        }
        // ISO strings without a zone designator, e.g. "2024-01-02T03:04:05".
        if string.count == 19, let d = iso.date(from: string + "Z") { return d }
        return nil
    }

    /// Interprets a number as seconds or milliseconds since 1970.
    public static func fromEpoch(_ value: Double) -> Date? {
        guard value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1000 : value)
    }

    public static func isoString(_ date: Date) -> String {
        isoFractional.string(from: date)
    }
}
