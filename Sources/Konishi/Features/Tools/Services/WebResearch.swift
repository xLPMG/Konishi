import Foundation
@preconcurrency import WebKit

enum WebResearch {
    // Generic browser compatibility token; it does not describe the user's actual OS or CPU.
    private static let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15)"
    private static let fetchTimeoutNanos: UInt64 = 15_000_000_000

    struct Result: Sendable {
        var text: String
        var sources: [Source]
    }

    private struct Page: Sendable {
        var index: Int
        var source: Source
        var text: String
    }

    struct ImageHit: Decodable, Sendable {
        var title: String
        var image: String
        var thumbnail: String?
        var url: String
    }

    struct FetchedImage: Sendable {
        var title: String
        var sourceURL: String
        var dataURL: String
    }

    struct ImageSearchResult: Sendable {
        var text: String
        var images: [FetchedImage]
        var sources: [Source]
    }

    private struct ImageSearchResponse: Decodable {
        var results: [ImageHit]
    }

    private struct IndexedImage: Sendable {
        var index: Int
        var image: FetchedImage?
    }

    private struct FetchTimeout: Error {}

    private static let maxImageBytes = 2 * 1024 * 1024
    private static let imageTokenRegex = try! NSRegularExpression(pattern: #"vqd=([0-9-]+)"#)

    // DuckDuckGo's lite result markup is stable and non-JS, so plain regex is sufficient here.
    private static let resultRegex = try! NSRegularExpression(
        pattern: #"class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#,
        options: [.dotMatchesLineSeparators]
    )
    private static let snippetRegex = try! NSRegularExpression(
        pattern: #"class="result__snippet"[^>]*>(.*?)</a>"#,
        options: [.dotMatchesLineSeparators]
    )
    private static let tagRegex = try! NSRegularExpression(pattern: "<[^>]+>", options: [])

    static func search(_ query: String, limit: Int = 6) async -> Result {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)") else {
            return Result(text: "Bad query", sources: [])
        }
        do {
            var request = URLRequest(url: url)
            request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return Result(text: "Search request failed.", sources: [])
            }
            let html = String(decoding: data, as: UTF8.self)
            let fullRange = NSRange(html.startIndex..., in: html)
            var sources: [Source] = []
            var lines: [String] = []
            for match in resultRegex.matches(in: html, range: fullRange) {
                guard sources.count < max(1, min(limit, 10)) else { break }
                guard let hrefRange = Range(match.range(at: 1), in: html),
                      let titleRange = Range(match.range(at: 2), in: html) else { continue }
                let href = decodeRedirect(String(html[hrefRange]))
                let title = stripTags(String(html[titleRange])).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, !href.isEmpty else { continue }
                var snippet = ""
                if let snippetMatch = snippetRegex.firstMatch(in: html, range: match.range),
                   let snippetRange = Range(snippetMatch.range(at: 1), in: html) {
                    snippet = stripTags(String(html[snippetRange])).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                sources.append(Source(title: title, url: href))
                lines.append("\(sources.count). \(title)\(snippet.isEmpty ? "" : " — \(snippet)") (\(href))")
            }
            return Result(
                text: lines.isEmpty ? "No results." : lines.joined(separator: "\n"),
                sources: sources
            )
        } catch {
            return Result(text: "Search error: \(error.localizedDescription)", sources: [])
        }
    }

    static func searchImages(_ query: String, limit: Int = 4) async -> ImageSearchResult {
        let query = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !query.isEmpty,
              var landing = URLComponents(string: "https://duckduckgo.com/") else {
            return ImageSearchResult(text: "Image search requires a query.", images: [], sources: [])
        }
        landing.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "iax", value: "images"),
            URLQueryItem(name: "ia", value: "images"),
        ]
        guard let landingURL = landing.url else {
            return ImageSearchResult(text: "Could not create image search URL.", images: [], sources: [])
        }

        do {
            var request = URLRequest(url: landingURL)
            request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 15
            let (htmlData, landingResponse) = try await URLSession.shared.data(for: request)
            guard let landingHTTP = landingResponse as? HTTPURLResponse,
                  (200..<300).contains(landingHTTP.statusCode),
                  let token = imageSearchToken(from: String(decoding: htmlData, as: UTF8.self))
            else {
                return ImageSearchResult(text: "Could not start image search.", images: [], sources: [])
            }

            guard var results = URLComponents(string: "https://duckduckgo.com/i.js") else {
                return ImageSearchResult(text: "Could not create image search URL.", images: [], sources: [])
            }
            results.queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "o", value: "json"),
                URLQueryItem(name: "vqd", value: token),
            ]
            guard let resultsURL = results.url else {
                return ImageSearchResult(text: "Could not create image search URL.", images: [], sources: [])
            }

            var resultsRequest = URLRequest(url: resultsURL)
            resultsRequest.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
            resultsRequest.setValue(landingURL.absoluteString, forHTTPHeaderField: "Referer")
            resultsRequest.timeoutInterval = 15
            let (resultsData, resultsResponse) = try await URLSession.shared.data(for: resultsRequest)
            guard let resultsHTTP = resultsResponse as? HTTPURLResponse,
                  (200..<300).contains(resultsHTTP.statusCode),
                  let hits = parseImageSearchResponse(resultsData)
            else {
                return ImageSearchResult(text: "Image search returned an unreadable response.", images: [], sources: [])
            }

            let selected = Array(hits.prefix(max(1, min(limit, 4))))
            let downloads = await withTaskGroup(of: IndexedImage.self) { group in
                for (index, hit) in selected.enumerated() {
                    group.addTask {
                        IndexedImage(index: index, image: await fetchImage(hit))
                    }
                }
                var collected: [IndexedImage] = []
                for await image in group { collected.append(image) }
                return collected.sorted { $0.index < $1.index }
            }

            var fetchedByIndex: [Int: FetchedImage] = [:]
            for download in downloads {
                if let image = download.image { fetchedByIndex[download.index] = image }
            }
            let sources = selected.compactMap { hit -> Source? in
                guard let pageURL = safePageURL(hit.url) else { return nil }
                return Source(title: hit.title, url: pageURL.absoluteString)
            }
            let lines = selected.enumerated().map { index, hit in
                let title = hit.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let source = safePageURL(hit.url)?.absoluteString ?? "(source URL unavailable)"
                let status = fetchedByIndex[index] == nil ? "image unavailable" : "image attached"
                return "\(index + 1). \(title.isEmpty ? "Image result" : title) — \(source) [\(status)]"
            }
            let images = downloads.compactMap(\.image)
            return ImageSearchResult(
                text: lines.isEmpty ? "No image results." : lines.joined(separator: "\n"),
                images: images,
                sources: sources)
        } catch {
            return ImageSearchResult(
                text: "Image search error: \(error.localizedDescription)", images: [], sources: [])
        }
    }

    static func imageSearchToken(from html: String) -> String? {
        let range = NSRange(html.startIndex..., in: html)
        guard let match = imageTokenRegex.firstMatch(in: html, range: range),
              let tokenRange = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[tokenRange])
    }

    static func parseImageSearchResponse(_ data: Data) -> [ImageHit]? {
        try? JSONDecoder().decode(ImageSearchResponse.self, from: data).results
    }

    static func imageMimeType(for data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.count >= 6, String(decoding: bytes[0..<6], as: UTF8.self).hasPrefix("GIF8") {
            return "image/gif"
        }
        if bytes.count >= 12, String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF",
           String(decoding: bytes[8..<12], as: UTF8.self) == "WEBP" {
            return "image/webp"
        }
        return nil
    }

    private static func fetchImage(_ hit: ImageHit) async -> FetchedImage? {
        let candidates = [hit.image, hit.thumbnail].compactMap { $0 }
        for candidate in candidates {
            guard let url = safeImageURL(candidate),
                  let (data, mimeType) = await downloadImage(from: url) else { continue }
            guard let sourceURL = safePageURL(hit.url)?.absoluteString else { continue }
            let title = hit.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return FetchedImage(
                title: title.isEmpty ? "Web image" : title,
                sourceURL: sourceURL,
                dataURL: "data:\(mimeType);base64,\(data.base64EncodedString())")
        }
        return nil
    }

    private static func downloadImage(from url: URL) async -> (Data, String)? {
        var request = URLRequest(url: url)
        request.setValue("image/avif,image/webp,image/png,image/jpeg,image/gif,*/*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let finalURL = response.url, safeImageURL(finalURL),
                  http.expectedContentLength < 0 || http.expectedContentLength <= maxImageBytes
            else { return nil }

            var data = Data()
            for try await byte in bytes {
                guard data.count < maxImageBytes else { return nil }
                data.append(byte)
            }
            guard let mimeType = imageMimeType(for: data) else { return nil }
            return (data, mimeType)
        } catch {
            return nil
        }
    }

    private static func safeImageURL(_ value: String) -> URL? {
        guard let url = URL(string: value) else { return nil }
        return safeImageURL(url) ? url : nil
    }

    private static func safeImageURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              let host = components.host?.lowercased(), host.contains("."),
              host != "localhost", !host.hasSuffix(".localhost"),
              !host.hasSuffix(".local"), !host.hasSuffix(".internal"),
              !host.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || $0 == 46 }),
              !host.contains(":") else { return false }
        return true
    }

    private static func safePageURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func fetch(_ url: URL, limit: Int = 8_000) async -> String {
        do {
            let raw = try await renderedText(url: url)
            let clean = raw
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? "(no readable text)" : String(clean.prefix(max(500, limit)))
        } catch {
            return "Error fetching: \(error.localizedDescription)"
        }
    }

    static func research(_ query: String, maxSources: Int) async -> Result {
        let count = max(1, min(maxSources, 6))
        let searchResult = await search(query, limit: count * 2)
        var selected: [Source] = []
        var hosts = Set<String>()
        for source in searchResult.sources {
            let host = URL(string: source.url)?.host?.lowercased() ?? source.url
            if hosts.insert(host).inserted { selected.append(source) }
            if selected.count == count { break }
        }
        guard !selected.isEmpty else { return searchResult }

        let pages = await withTaskGroup(of: Page?.self, returning: [Page].self) { group in
            for (index, source) in selected.enumerated() {
                group.addTask {
                    guard let url = URL(string: source.url) else { return nil }
                    let text = await fetch(url, limit: 6_000)
                    guard !text.hasPrefix("Error fetching:") else { return nil }
                    return Page(index: index, source: source, text: text)
                }
            }
            var pages: [Page] = []
            for await page in group {
                if let page { pages.append(page) }
            }
            return pages.sorted { $0.index < $1.index }
        }
        guard !pages.isEmpty else { return searchResult }
        let text = pages.map { page in
            "## Source \(page.index + 1): \(page.source.title)\nURL: \(page.source.url)\n\(page.text)"
        }.joined(separator: "\n\n")
        return Result(text: String(text.prefix(24_000)), sources: pages.map(\.source))
    }

    private static func decodeRedirect(_ href: String) -> String {
        let value = href.hasPrefix("//") ? "https:" + href : href
        if let components = URLComponents(string: value),
           let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value {
            return target
        }
        return value.hasPrefix("http") ? value : ""
    }

    private static func stripTags(_ html: String) -> String {
        let range = NSRange(html.startIndex..., in: html)
        return tagRegex.stringByReplacingMatches(in: html, range: range, withTemplate: "")
    }

    // MARK: - Readable text extraction via a real rendering engine (accurate on JS-driven pages, no parsing dependency)

    private static let extractionScript = """
    (function() {
        document.querySelectorAll('script,style,noscript,nav,footer,header,form,svg,iframe').forEach(function(e) { e.remove(); });
        var el = document.querySelector('article,main') || document.body;
        return el ? el.innerText : '';
    })();
    """

    @MainActor
    private final class NavigationWaiter: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?

        func wait() async throws {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            continuation?.resume(throwing: error)
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    @MainActor
    private static func renderedText(url: URL) async throws -> String {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1200, height: 2000), configuration: config)
        webView.customUserAgent = browserUserAgent
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        webView.load(URLRequest(url: url))

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await waiter.wait() }
            group.addTask {
                try await Task.sleep(nanoseconds: fetchTimeoutNanos)
                throw FetchTimeout()
            }
            try await group.next()
            group.cancelAll()
        }

        let value = try await webView.evaluateJavaScript(extractionScript)
        return (value as? String) ?? ""
    }
}