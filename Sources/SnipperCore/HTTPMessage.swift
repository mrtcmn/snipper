import Foundation

/// A parsed HTTP/1.1 request, as received by the app's local API server.
public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Header names are lowercased.
    public var headers: [String: String]
    public var body: Data

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    public func jsonObject() -> Any? {
        body.isEmpty ? nil : try? JSONSerialization.jsonObject(with: body)
    }
}

public enum HTTPParseResult {
    case incomplete
    case complete(HTTPRequest)
    case invalid(status: Int, reason: String)
}

public enum HTTPRequestParser {
    private static let headerTerminator = Data("\r\n\r\n".utf8)

    /// Parses `buffer` if it holds a full request. Bodies must use Content-Length.
    public static func parse(_ buffer: Data, maxHeaderBytes: Int = 32 * 1024, maxBodyBytes: Int) -> HTTPParseResult {
        guard let end = buffer.range(of: headerTerminator) else {
            return buffer.count > maxHeaderBytes ? .invalid(status: 431, reason: "Headers too large") : .incomplete
        }
        guard let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8)
                ?? String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .isoLatin1)
        else { return .invalid(status: 400, reason: "Unreadable headers") }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { return .invalid(status: 400, reason: "Bad request line") }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        if let te = headers["transfer-encoding"], te.lowercased() != "identity" {
            return .invalid(status: 411, reason: "Chunked bodies are not supported")
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .invalid(status: 400, reason: "Bad Content-Length") }
        guard length <= maxBodyBytes else { return .invalid(status: 413, reason: "Body too large") }

        let bodyStart = end.upperBound
        guard buffer.endIndex - bodyStart >= length else { return .incomplete }
        let body = Data(buffer[bodyStart..<(bodyStart + length)])

        let target = String(requestLine[1])
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }

        return .complete(HTTPRequest(
            method: String(requestLine[0]).uppercased(),
            path: components?.percentEncodedPath.removingPercentEncoding ?? target,
            query: query,
            headers: headers,
            body: body
        ))
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: [("Content-Type", "application/json; charset=utf-8")], body: body)
    }

    public static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(["ok": false, "error": message], status: status)
    }

    public func adding(_ name: String, _ value: String) -> HTTPResponse {
        var copy = self
        copy.headers.append((name, value))
        return copy
    }

    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        var names = Set<String>()
        for (name, value) in headers {
            head += "\(name): \(value)\r\n"
            names.insert(name.lowercased())
        }
        if !names.contains("content-length") { head += "Content-Length: \(body.count)\r\n" }
        if !names.contains("connection") { head += "Connection: close\r\n" }
        head += "Cache-Control: no-store\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 204: "No Content"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 411: "Length Required"
        case 413: "Payload Too Large"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }
}

/// Decides which callers may use the local API.
///
/// Browsers attach an `Origin` header that web pages cannot forge, and a custom header
/// cannot be sent cross-origin without a CORS preflight, which is only granted to
/// browser extensions. Together these keep websites from writing to the library.
public enum LocalAPIAccess {
    public static let clientHeader = "x-snipper-client"

    public static func isAllowedOrigin(_ origin: String?) -> Bool {
        guard let origin, !origin.isEmpty else { return true } // Local tools such as curl or Shortcuts.
        return origin.hasPrefix("chrome-extension://")
    }

    public static func authorize(_ request: HTTPRequest) -> Bool {
        guard isAllowedOrigin(request.header("origin")) else { return false }
        return request.header(clientHeader) != nil
    }

    /// CORS headers for an allowed origin.
    public static func corsHeaders(for origin: String?) -> [(String, String)] {
        guard let origin, isAllowedOrigin(origin), !origin.isEmpty else { return [] }
        return [
            ("Access-Control-Allow-Origin", origin),
            ("Access-Control-Allow-Methods", "GET, POST, OPTIONS"),
            ("Access-Control-Allow-Headers", "Content-Type, X-Snipper-Client"),
            ("Access-Control-Allow-Private-Network", "true"),
            ("Access-Control-Max-Age", "600"),
            ("Vary", "Origin"),
        ]
    }
}
