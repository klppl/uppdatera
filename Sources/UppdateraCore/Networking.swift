import Foundation

public enum HTTP {
    public static let userAgent = "Uppdatera/1.0 (macOS updater; +https://github.com/)"

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpMaximumConnectionsPerHost = 4
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        return URLSession(configuration: config)
    }()

    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static func data(_ url: URL, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure(message: "No HTTP response from \(url.host ?? "server")") }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure(message: "\(url.host ?? "Server") answered \(http.statusCode)")
        }
        return (data, http)
    }

    public static func json(_ url: URL, headers: [String: String] = [:]) async throws -> Any {
        let (data, _) = try await data(url, headers: headers)
        return try JSONSerialization.jsonObject(with: data)
    }

    /// Follows redirects and returns the final URL, e.g. for `…/releases/latest`.
    public static func finalURL(_ url: URL) async throws -> URL {
        try await head(url).url ?? url
    }

    /// HEAD, falling back to a one-byte GET for servers that refuse HEAD.
    public static func head(_ url: URL) async throws -> HTTPURLResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        if let (_, response) = try? await session.data(for: request),
           let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) {
            return http
        }
        request.httpMethod = "GET"
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
            throw Failure(message: "\(url.host ?? "Server") refused the request")
        }
        return http
    }

    public static func text(_ url: URL) async throws -> String {
        let (data, _) = try await data(url)
        return String(decoding: data, as: UTF8.self)
    }
}

/// First capture group of `pattern` in `text` (or the whole match when there is no group).
public func firstMatch(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
          let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
    let range = m.numberOfRanges > 1 ? m.range(at: 1) : m.range
    return Range(range, in: text).map { String(text[$0]) }
}

/// Runs work with at most `limit` tasks in flight.
public func boundedMap<T: Sendable, R: Sendable>(_ items: [T], limit: Int, _ body: @escaping @Sendable (T) async -> R) async -> [R] {
    await withTaskGroup(of: (Int, R).self) { group in
        var results = [R?](repeating: nil, count: items.count)
        var next = 0
        while next < min(limit, items.count) {
            let i = next, item = items[i]
            group.addTask { (i, await body(item)) }
            next += 1
        }
        while let (i, r) = await group.next() {
            results[i] = r
            if next < items.count {
                let j = next, item = items[j]
                group.addTask { (j, await body(item)) }
                next += 1
            }
        }
        return results.compactMap { $0 }
    }
}

/// Walks a dotted path such as `releases.0.version` through decoded JSON.
public func valueAt(path: String, in object: Any) -> Any? {
    var current: Any? = object
    for key in path.split(separator: ".") {
        if let dict = current as? [String: Any] {
            current = dict[String(key)]
        } else if let array = current as? [Any], let i = Int(key), i < array.count {
            current = array[i]
        } else {
            return nil
        }
    }
    return current
}
