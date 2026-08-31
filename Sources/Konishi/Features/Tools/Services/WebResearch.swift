import Foundation
import SwiftSoup

enum WebResearch {
    // Generic browser compatibility token; it does not describe the user's actual OS or CPU.
    private static let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15)"

    struct Result: Sendable {
        var text: String
        var sources: [Source]
    }

    private struct Page: Sendable {
        var index: Int
        var source: Source
        var text: String
    }

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
            let document = try SwiftSoup.parse(String(decoding: data, as: UTF8.self))
            var sources: [Source] = []
            var lines: [String] = []
            for result in try document.select(".result") {
                guard sources.count < max(1, min(limit, 10)),
                      let anchor = try result.select("a.result__a").first() else { continue }
                let title = try anchor.text().trimmingCharacters(in: .whitespacesAndNewlines)
                let href = decodeRedirect(try anchor.attr("href"))
                guard !title.isEmpty, !href.isEmpty else { continue }
                let snippet = try result.select(".result__snippet").first()?.text() ?? ""
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
            var request = URLRequest(url: url)
            request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return "Error fetching: HTTP request failed"
            }
            let document = try SwiftSoup.parse(String(decoding: data, as: UTF8.self), url.absoluteString)
            try document.select("script,style,noscript,nav,footer,header,form,svg").remove()
            let preferred = try document.select("article,main").first()
            let text = try (preferred ?? document.body())?.text() ?? ""
            let clean = text
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
}