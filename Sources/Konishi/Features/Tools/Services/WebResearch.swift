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

    private struct FetchTimeout: Error {}

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