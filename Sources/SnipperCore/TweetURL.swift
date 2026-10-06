import Foundation

/// A reference to one post on X.
public struct TweetReference: Equatable, Hashable, Sendable {
    public var id: String
    public var handle: String?

    public init(id: String, handle: String? = nil) {
        self.id = id
        self.handle = handle
    }

    public var canonicalURL: String {
        if let handle, !handle.isEmpty { return "https://x.com/\(handle)/status/\(id)" }
        return "https://x.com/i/web/status/\(id)"
    }

    /// De-duplication key used by `Snip.externalID`.
    public var externalID: String { TweetReference.externalID(for: id) }

    public static func externalID(for tweetID: String) -> String { "x:\(tweetID)" }
}

public enum TweetURL {
    private static let hosts: Set<String> = [
        "x.com", "twitter.com", "mobile.twitter.com", "mobile.x.com",
        "fxtwitter.com", "vxtwitter.com", "fixupx.com", "fixvx.com", "twittpr.com", "nitter.net",
    ]
    /// Path segments that look like handles but are app routes.
    private static let reservedHandles: Set<String> = ["i", "home", "explore", "search", "settings", "notifications", "messages"]

    public static func isPostHost(_ host: String) -> Bool {
        var h = host.lowercased()
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return hosts.contains(h)
    }

    /// Parses links such as `https://x.com/user/status/123`, `twitter.com/i/web/status/123`
    /// or `x.com/user/status/123/photo/1`.
    public static func parse(_ string: String) -> TweetReference? {
        var raw = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains("://") { raw = "https://" + raw }
        guard let url = URL(string: raw), let host = url.host, isPostHost(host) else { return nil }

        let parts = url.path.split(separator: "/").map(String.init)
        guard let statusIndex = parts.firstIndex(where: { $0 == "status" || $0 == "statuses" }),
              statusIndex + 1 < parts.count
        else { return nil }

        let id = parts[statusIndex + 1]
        guard !id.isEmpty, id.count <= 20, id.allSatisfy(\.isASCIIDigit) else { return nil }

        var handle: String?
        if statusIndex >= 1 {
            let candidate = parts[statusIndex - 1]
            if !reservedHandles.contains(candidate.lowercased()) && candidate != "web" {
                handle = candidate
            }
        }
        return TweetReference(id: id, handle: handle)
    }
}

extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

/// The `token` query parameter expected by X's public embed endpoint
/// (`cdn.syndication.twimg.com/tweet-result`).
///
/// It is defined in JavaScript as
/// `((Number(id) / 1e15) * Math.PI).toString(36).replace(/(0+|\.)/g, '')`,
/// so this ports V8's `Number.prototype.toString(radix)` for fractional values.
public enum SyndicationToken {
    public static func token(for tweetID: String) -> String {
        guard let id = Double(tweetID) else { return "0" }
        let value = (id / 1e15) * Double.pi
        return radixString(value, radix: 36).filter { $0 != "0" && $0 != "." }
    }

    private static let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")

    /// Port of V8's `DoubleToRadixCString`.
    public static func radixString(_ input: Double, radix: Int) -> String {
        precondition((2...36).contains(radix))
        guard input.isFinite else { return input.isNaN ? "NaN" : (input < 0 ? "-Infinity" : "Infinity") }
        if input == 0 { return "0" }

        let negative = input < 0
        let value = abs(input)
        let r = Double(radix)

        var integer = value.rounded(.down)
        var fraction = value - integer
        var delta = 0.5 * (value.nextUp - value)
        delta = max(Double.leastNonzeroMagnitude, delta)

        var fractionDigits: [Character] = []
        if fraction >= delta {
            repeat {
                fraction *= r
                delta *= r
                let digit = Int(fraction)
                fractionDigits.append(digits[digit])
                fraction -= Double(digit)
                // Round to even.
                if fraction > 0.5 || (fraction == 0.5 && (digit & 1) == 1) {
                    if fraction + delta > 1 {
                        // Propagate the carry through the digits already written.
                        while true {
                            guard let last = fractionDigits.popLast() else {
                                integer += 1
                                break
                            }
                            let d = digits.firstIndex(of: last)!
                            if d + 1 < radix {
                                fractionDigits.append(digits[d + 1])
                                break
                            }
                        }
                        break
                    }
                }
            } while fraction >= delta
        }

        // Integer digits; digits beyond double precision are filled with zeros.
        var integerDigits: [Character] = []
        while (integer / r) >= 9_007_199_254_740_992 {
            integer /= r
            integerDigits.append("0")
        }
        repeat {
            let remainder = integer.truncatingRemainder(dividingBy: r)
            integerDigits.append(digits[Int(remainder)])
            integer = (integer - remainder) / r
        } while integer > 0

        var result = negative ? "-" : ""
        result += String(integerDigits.reversed())
        if !fractionDigits.isEmpty {
            result += "." + String(fractionDigits)
        }
        return result
    }
}
