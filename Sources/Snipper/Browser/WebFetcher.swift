import Foundation
import SnipperCore

/// Fetches posts and link previews from the web.
enum WebFetcher {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
            "Accept-Language": "en-US,en;q=0.9",
        ]
        return URLSession(configuration: config)
    }()

    enum FetchError: LocalizedError {
        case status(Int)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .status(let code): "The server answered with status \(code)."
            case .unreadable: "The page couldn't be read."
            }
        }
    }

    /// Loads a post from X's public embed endpoint, falling back to oEmbed.
    static func post(_ reference: TweetReference, source: String) async throws -> Snip {
        var components = URLComponents(string: "https://cdn.syndication.twimg.com/tweet-result")!
        components.queryItems = [
            URLQueryItem(name: "id", value: reference.id),
            URLQueryItem(name: "lang", value: "en"),
            URLQueryItem(name: "token", value: SyndicationToken.token(for: reference.id)),
        ]
        do {
            let data = try await get(components.url!)
            return try SyndicationParser.snip(from: data, source: source)
        } catch {
            logger.info("Embed JSON unavailable for \(reference.id, privacy: .public), trying oEmbed: \(error.localizedDescription, privacy: .public)")
        }

        var oembed = URLComponents(string: "https://publish.twitter.com/oembed")!
        let handle = reference.handle ?? "i"
        oembed.queryItems = [
            URLQueryItem(name: "url", value: "https://twitter.com/\(handle)/status/\(reference.id)"),
            URLQueryItem(name: "omit_script", value: "true"),
            URLQueryItem(name: "dnt", value: "true"),
        ]
        let data = try await get(oembed.url!)
        return try OEmbedParser.snip(from: data, reference: reference, source: source)
    }

    /// Builds a link snip with title, description and preview image. Never fails: without
    /// network it returns a bare link.
    static func link(_ url: URL, title fallbackTitle: String?, source: String) async -> Snip {
        var snip = Snip(
            kind: .link,
            title: fallbackTitle ?? "",
            url: url.absoluteString,
            source: source,
            externalID: "url:\(URLNormalizer.normalize(url.absoluteString))",
            link: LinkInfo(url: url.absoluteString, title: fallbackTitle)
        )
        guard let result = try? await session.data(from: url) else { return snip }
        let (data, response) = result
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return snip }
        guard (response.mimeType ?? "text/html").contains("html") else { return snip }
        let html = decodeHTML(data, encodingName: response.textEncodingName)
        let parsed = LinkMetadataParser.parse(html: html, pageURL: response.url ?? url)
        snip.link = parsed.info
        if let title = parsed.title, !title.isEmpty { snip.title = title }
        if let image = parsed.info.imageURL {
            snip.media = [SnipMedia(kind: .image, remoteURL: image)]
        }
        return snip
    }

    static func get(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FetchError.status(http.statusCode)
        }
        return data
    }

    private static func decodeHTML(_ data: Data, encodingName: String?) -> String {
        if let name = encodingName {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let s = String(data: data, encoding: encoding) { return s }
            }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }
}
