import Foundation

/// Manages the Markdown memory files under `~/Konishi/memory/<scope>/` (or `root`, when injected for tests).
struct MemoryStore {
    static let globalScope = "global"

    private let root: URL
    private let backupsRoot: URL

    init(root: URL = Paths.memory, backupsRoot: URL = Paths.memoryBackups) {
        self.root = root
        self.backupsRoot = backupsRoot
    }

    struct File: Identifiable, Hashable {
        var id: String { scope + "/" + name }
        let scope: String
        let name: String
        let url: URL
    }

    private func scopeDir(_ scope: String) -> URL {
        let url = root.appendingPathComponent(scope, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Builds a `File` for a scope/name without requiring it to already exist on disk.
    func file(scope: String, name: String) -> File {
        File(scope: scope, name: name, url: scopeDir(scope).appendingPathComponent(name))
    }

    func files(in scope: String) -> [File] {
        let dir = scopeDir(scope)
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil
            )) ?? []
        return
            contents
            .filter { $0.pathExtension.lowercased() == "md" }
            .map { File(scope: scope, name: $0.lastPathComponent, url: $0) }
            .sorted { $0.name < $1.name }
    }

    func read(_ file: File) -> String {
        (try? String(contentsOf: file.url, encoding: .utf8)) ?? ""
    }

    func write(scope: String, name: String, content: String) {
        let fileName = name.hasSuffix(".md") ? name : name + ".md"
        let url = scopeDir(scope).appendingPathComponent(fileName)
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    func append(scope: String, name: String, content: String) {
        let existing = read(
            File(
                scope: scope, name: name, url: scopeDir(scope).appendingPathComponent(name)
            ))
        let separator = existing.isEmpty ? "" : "\n\n"
        write(scope: scope, name: name, content: existing + separator + content)
    }

    func delete(_ file: File) {
        try? FileManager.default.removeItem(at: file.url)
    }

    func delete(scope: String, name: String) {
        let url = scopeDir(scope).appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
    }

    /// Concatenated Markdown for the given scopes, for system-prompt injection.
    func combined(scopes: [String]) -> String {
        var blocks: [String] = []
        for scope in scopes {
            for file in files(in: scope) {
                let text = read(file).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                blocks.append("## \(scope)/\(file.name)\n\(text)")
            }
        }
        return blocks.joined(separator: "\n\n")
    }

    /// A cheap change-signature (file names + modification times) for the given scopes, used to
    /// validate a cache of `combined(scopes:)` without reading every file's body each turn.
    func signature(scopes: [String]) -> String {
        var parts: [String] = []
        for scope in scopes {
            for file in files(in: scope) {
                let mtime =
                    (try? file.url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate)?.timeIntervalSince1970 ?? 0
                parts.append("\(scope)/\(file.name):\(mtime)")
            }
        }
        return parts.joined(separator: "|")
    }

    /// Copies every memory file in the given scopes into a timestamped backup folder. Returns it,
    /// or nil if there was nothing to back up.
    @discardableResult
    func backup(scopes: [String]) -> URL? {
        let fm = FileManager.default
        let dest = backupsRoot.appendingPathComponent(Self.backupStamp(), isDirectory: true)
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        var copied = false
        for scope in scopes {
            let scopeFiles = files(in: scope)
            guard !scopeFiles.isEmpty else { continue }
            let dir = dest.appendingPathComponent(scope, isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for file in scopeFiles {
                try? fm.copyItem(at: file.url, to: dir.appendingPathComponent(file.name))
                copied = true
            }
        }
        return copied ? dest : nil
    }

    private static func backupStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }

    /// Splits a memory file into individual bullet/line blocks. Structured memory files are
    /// single-newline bullet lists, so retrieval and counting must work line-by-line.
    static func blocks(_ text: String) -> [String] {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 3 }
    }

    /// Total number of bullet lines across all memory files in a scope (memory "size").
    func bulletCount(in scope: String) -> Int {
        files(in: scope).reduce(0) { $0 + Self.blocks(read($1)).count }
    }

    /// Result of a retrieval pass: the injected context, plus enough to let the caller record a trace.
    struct Retrieval {
        struct Trace {
            let kind: TraceEntry.Kind
            let text: String
            let detail: String
        }
        let text: String
        let trace: Trace?
        /// Short-term facts that were injected, so the caller can record the retrieval.
        var stmHits: [UUID] = []
    }

    /// Injects the user's identity (global profile) in full plus the top-K bullets most relevant
    /// to the current query, so memory can grow large without flooding the context.  When an
    /// embeddings endpoint is available, lexical BM25 and semantic similarity are combined;
    /// otherwise BM25 remains a useful fully-local fallback. Pending short-term facts compete
    /// with long-term bullets on equal terms.
    @MainActor
    func retrieve(
        scopes: [String], query: String, cache: EmbeddingCache,
        requestConfig: RequestConfig, threshold: Double, topK: Int,
        shortTerm: [STMFact] = []
    ) async -> Retrieval {
        let profileName = MemoryCategory.profile.fileName
        let profileScope = MemoryStore.globalScope
        let profileURL = scopeDir(profileScope).appendingPathComponent(profileName)
        let profileBody = self.read(
            MemoryStore.File(scope: profileScope, name: profileName, url: profileURL)
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        var sections: [String] = []
        if !profileBody.isEmpty {
            sections.append("## \(profileScope)/\(profileName)\n\(profileBody)")
        }

        // Every other bullet is a retrieval candidate.
        var chunks: [(label: String, text: String)] = []
        for scope in scopes {
            for file in self.files(in: scope) {
                if scope == profileScope, file.name == profileName { continue }
                for block in MemoryStore.blocks(self.read(file)) {
                    chunks.append((label: "\(scope)/\(file.name)", text: block))
                }
            }
        }
        let known = Set(chunks.map { MemoryProfile.normalizedFact($0.text) })
        var recentIDs: [String: UUID] = [:]
        for fact in shortTerm where scopes.contains(fact.scope) {
            let text = "- \(fact.text)"
            guard !known.contains(MemoryProfile.normalizedFact(text)) else { continue }
            chunks.append((label: "recent/\(fact.category.header.lowercased())", text: text))
            recentIDs[text] = fact.id
        }
        guard !chunks.isEmpty, !query.isEmpty else {
            return Retrieval(text: sections.joined(separator: "\n\n"), trace: nil)
        }
        let ranking = await MemoryRetrieval.rank(
            chunks: chunks, query: query, cache: cache, requestConfig: requestConfig,
            hybridThreshold: threshold, lexicalThreshold: 0.2)
        let scored = Array(ranking.scored.prefix(max(1, topK)))
        sections.append(contentsOf: MemoryRetrieval.groupedSections(scored))
        let hits = scored.compactMap { item in
            item.chunk.label.hasPrefix("recent/") ? recentIDs[item.chunk.text] : nil
        }
        let trace: Retrieval.Trace
        if let failure = ranking.failure {
            // An embeddings server is optional: retain targeted lexical retrieval when it is down.
            trace = Retrieval.Trace(
                kind: .error,
                text:
                    "memory embedding retrieval failed; BM25 fallback injected \(scored.count)/\(chunks.count) bullets: \(failure)",
                detail: MemoryRetrieval.traceDetail(scored))
        } else {
            trace = Retrieval.Trace(
                kind: .memory,
                text:
                    "memory retrieval: \(scored.count)/\(chunks.count) bullets ≥ \(String(format: "%.2f", threshold)) injected",
                detail: MemoryRetrieval.traceDetail(scored))
        }
        return Retrieval(text: sections.joined(separator: "\n\n"), trace: trace, stmHits: hits)
    }
}
