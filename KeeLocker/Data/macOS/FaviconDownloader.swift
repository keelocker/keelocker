import Foundation

struct FaviconResponse: Sendable {
    let data: Data
    let url: URL
}

struct FaviconDownloader: Sendable {
    typealias Loader = @Sendable (URL) async throws -> VaultCustomIcon
    typealias Fetcher = @Sendable (URL, Int) async throws -> FaviconResponse
    enum Failure: Error { case invalidWebsite, unavailable }
    private let fetch: Fetcher

    init(fetch: @escaping Fetcher = { try await Self.fetch($0, limit: $1) }) { self.fetch = fetch }

    // Never send a stored URL's credentials, path, query or fragment to a server.
    static func origin(for website: String) -> URL? {
        let text = website.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: text.contains("://") ? text : "https://" + text),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty, !host.contains(" ") else { return nil }
        parts.scheme = "https"
        parts.host = host.lowercased()
        if scheme == "http" { parts.port = nil }
        parts.user = nil
        parts.password = nil
        parts.path = "/"
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    func download(_ origin: URL) async throws -> VaultCustomIcon {
        guard let origin = Self.origin(for: origin.absoluteString) else { throw Failure.invalidWebsite }
        try Task.checkCancellation()
        var candidates: [URL] = []
        if let page = try? await fetch(origin, 1024 * 1024), page.data.count <= 1024 * 1024, Self.isAllowed(page.url) {
            candidates = Self.iconURLs(in: String(decoding: page.data, as: UTF8.self), relativeTo: page.url)
        }
        candidates.append(origin.appendingPathComponent("favicon.ico"))
        var seen: Set<URL> = []
        for url in candidates where seen.insert(url).inserted {
            try Task.checkCancellation()
            do {
                let response = try await fetch(url, 4 * 1024 * 1024)
                guard response.data.count <= 4 * 1024 * 1024, Self.isAllowed(response.url) else { continue }
                return try await Task.detached {
                    try IconImageImport.normalized(response.data, name: origin.host ?? "Website icon")
                }.value
            } catch {
                try Task.checkCancellation()
            }
        }
        throw Failure.unavailable
    }

    static func isAllowed(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false
            && url.user == nil && url.password == nil
    }

    static func iconURLs(in html: String, relativeTo base: URL) -> [URL] {
        guard html.utf8.count <= 1024 * 1024 else { return [] }
        let bytes = Array(html.utf8)
        var result: [(url: URL, rank: Int)] = []
        var cursor = 0
        // A single forward scan prevents regex backtracking on malformed tags.
        // Nested '<' restarts the tag at that byte rather than rescanning suffixes.
        while cursor < bytes.count {
            if Task.isCancelled { return [] }
            guard bytes[cursor] == 60 else { cursor += 1; continue }
            cursor += 1
            if cursor + 2 < bytes.count, bytes[cursor] == 33,
               bytes[cursor + 1] == 45, bytes[cursor + 2] == 45 {
                cursor += 3
                while cursor + 2 < bytes.count {
                    if Task.isCancelled { return [] }
                    if bytes[cursor] == 45, bytes[cursor + 1] == 45, bytes[cursor + 2] == 62 {
                        cursor += 3
                        break
                    }
                    cursor += 1
                }
                continue
            }
            let nameStart = cursor
            while cursor < bytes.count, isAttributeByte(bytes[cursor]) { cursor += 1 }
            let isLink = String(decoding: bytes[nameStart..<cursor], as: UTF8.self).lowercased() == "link"
            let attributesStart = cursor
            var quote: UInt8?
            while cursor < bytes.count {
                if Task.isCancelled { return [] }
                let byte = bytes[cursor]
                if let delimiter = quote {
                    if byte == delimiter { quote = nil }
                } else if byte == 34 || byte == 39 { quote = byte }
                else if byte == 60 || byte == 62 { break }
                cursor += 1
            }
            guard cursor < bytes.count else { break }
            guard bytes[cursor] == 62 else { continue }
            let end = cursor
            cursor += 1
            guard isLink else { continue }
            let values = iconAttributes(in: bytes[attributesStart..<end])
            let rel = (values["rel"] ?? "").lowercased().split(whereSeparator: { $0.isWhitespace })
            guard rel.contains("icon") || rel.contains("apple-touch-icon") || rel.contains("apple-touch-icon-precomposed"),
                  let href = values["href"],
                  let url = URL(string: href.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: base)?.absoluteURL,
                  isAllowed(url) else { continue }
            let touchIcon = rel.contains("apple-touch-icon") || rel.contains("apple-touch-icon-precomposed")
            let size = (values["sizes"] ?? "").split(whereSeparator: { $0.isWhitespace })
                .compactMap { Int($0.lowercased().split(separator: "x").first ?? "") }.max() ?? 0
            let rank = (touchIcon ? 1_000_000 : 0) + min(max(size, 0), 16_384)
            result.append((url, rank))
            if result.count == 32 { break }
        }
        // Prefer larger site artwork; retain document order for equal scores.
        let ranked = result.enumerated().sorted {
            $0.element.rank == $1.element.rank ? $0.offset < $1.offset : $0.element.rank > $1.element.rank
        }.map { $0.element.url }
        var seen: Set<URL> = []
        return Array(ranked.filter { seen.insert($0).inserted }.prefix(5))
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 32 || (9...13).contains(byte)
    }

    private static func isAttributeByte(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
            || byte == 45 || byte == 95 || byte == 58
    }

    private static func iconAttributes(in bytes: ArraySlice<UInt8>) -> [String: String] {
        var cursor = bytes.startIndex
        var values: [String: String] = [:]
        while cursor < bytes.endIndex {
            if Task.isCancelled { return [:] }
            guard isAttributeByte(bytes[cursor]) else { cursor += 1; continue }
            let nameStart = cursor
            while cursor < bytes.endIndex, isAttributeByte(bytes[cursor]) { cursor += 1 }
            let key = String(decoding: bytes[nameStart..<cursor], as: UTF8.self).lowercased()
            while cursor < bytes.endIndex, isSpace(bytes[cursor]) { cursor += 1 }
            guard cursor < bytes.endIndex, bytes[cursor] == 61 else { continue }
            cursor += 1
            while cursor < bytes.endIndex, isSpace(bytes[cursor]) { cursor += 1 }
            guard cursor < bytes.endIndex else { break }
            let delimiter: UInt8? = bytes[cursor] == 34 || bytes[cursor] == 39 ? bytes[cursor] : nil
            if delimiter != nil { cursor += 1 }
            let start = cursor
            while cursor < bytes.endIndex {
                if let delimiter { if bytes[cursor] == delimiter { break } }
                else if isSpace(bytes[cursor]) { break }
                cursor += 1
            }
            if ["href", "rel", "sizes"].contains(key), values[key] == nil {
                values[key] = String(decoding: bytes[start..<cursor], as: UTF8.self)
            }
            if delimiter != nil, cursor < bytes.endIndex { cursor += 1 }
        }
        return values
    }

    private static func fetch(_ url: URL, limit: Int) async throws -> FaviconResponse {
        guard isAllowed(url) else { throw Failure.unavailable }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 7
        configuration.timeoutIntervalForResource = 12
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("KeeLocker", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request, delegate: FaviconRedirectPolicy())
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              let finalURL = response.url, isAllowed(finalURL),
              response.expectedContentLength <= Int64(limit) else { throw Failure.unavailable }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw Failure.unavailable }
            data.append(byte)
        }
        return FaviconResponse(data: data, url: finalURL)
    }
}

private final class FaviconRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    // URLSession serializes callbacks on its delegate queue; each request has its own policy.
    private var redirects = 0

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 3, let url = request.url, FaviconDownloader.isAllowed(url) else {
            completionHandler(nil)
            return
        }
        completionHandler(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
    }
}
