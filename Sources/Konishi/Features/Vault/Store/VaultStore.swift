import Foundation

/// Reads and writes an external Obsidian vault (a folder of Markdown notes) and provides
/// embedding-based retrieval over it. The vault lives outside Konishi and may be edited in
/// Obsidian, so notes are re-scanned whenever their modification times change.
@MainActor
final class VaultStore {
    struct Chunk { let label: String; let text: String }

    /// Cached chunks for the last scanned vault, keyed by a path + mtime signature.
    private var cache: (path: String, signature: String, chunks: [Chunk])?

    // MARK: - Location

    /// The vault root as a URL, or nil if the path is empty or not an existing directory.
    static func vaultURL(_ vaultPath: String) -> URL? {
        let expanded = (vaultPath as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue
        else { return nil }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }

    private static let skipDirs: Set<String> = [".obsidian", ".trash", ".git"]

    /// All Markdown files in the vault, skipping Obsidian/system folders.
    static func markdownFiles(in vault: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let en = FileManager.default.enumerator(
            at: vault, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [URL] = []
        for case let url as URL in en {
            if url.hasDirectoryPath {
                if skipDirs.contains(url.lastPathComponent) { en.skipDescendants() }
                continue
            }
            if url.pathExtension.lowercased() == "md" { out.append(url) }
        }
        return out
    }

    /// Vault-relative path for a note URL (e.g. "Literature/Smith2020.md").
    private static func label(for url: URL, vault: URL) -> String {
        let full = url.standardizedFileURL.path
        let root = vault.path.hasSuffix("/") ? vault.path : vault.path + "/"
        return full.hasPrefix(root) ? String(full.dropFirst(root.count)) : url.lastPathComponent
    }

    // MARK: - Retrieval

    private func chunks(vaultPath: String) -> [Chunk] {
        guard let vault = Self.vaultURL(vaultPath) else { return [] }
        let files = Self.markdownFiles(in: vault)
        let signature = files.map { url -> String in
            let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate)?.timeIntervalSince1970 ?? 0
            return "\(url.path):\(m)"
        }.sorted().joined(separator: "|")
        if let c = cache, c.path == vault.path, c.signature == signature { return c.chunks }

        var chunks: [Chunk] = []
        for url in files {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let label = Self.label(for: url, vault: vault)
            for piece in DocumentStore.chunks(text) {
                let t = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.count >= 3 { chunks.append(Chunk(label: label, text: t)) }
            }
        }
        cache = (vault.path, signature, chunks)
        return chunks
    }

    /// Top-K relevant passages across the vault, formatted for prompt injection.
    func context(
        vaultPath: String, query: String, cache: EmbeddingCache, topK: Int,
        requestConfig: RequestConfig
    ) async -> HybridRetrieval.Context {
        let chunks = self.chunks(vaultPath: vaultPath)
        return await HybridRetrieval.retrieve(
            chunks: chunks.map { (label: $0.label, text: $0.text) },
            query: query, cache: cache, requestConfig: requestConfig,
            topK: topK, hybridThreshold: 0, lexicalThreshold: 0.15)
    }

    // MARK: - Note access (tools)

    func list(vaultPath: String, folder: String?) -> [String] {
        guard let vault = Self.vaultURL(vaultPath) else { return [] }
        var labels = Self.markdownFiles(in: vault).map { Self.label(for: $0, vault: vault) }.sorted()
        if let folder, !folder.trimmingCharacters(in: .whitespaces).isEmpty {
            let prefix = folder.hasSuffix("/") ? folder : folder + "/"
            labels = labels.filter { $0.hasPrefix(prefix) }
        }
        return labels
    }

    func read(vaultPath: String, note: String) -> String? {
        guard let vault = Self.vaultURL(vaultPath),
            let url = Self.resolve(note: note, in: vault, forWriting: false),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return text
    }

    /// Create, overwrite, or append to a note. Returns the vault-relative path written, or nil.
    func write(vaultPath: String, note: String, content: String, append: Bool) -> String? {
        guard let vault = Self.vaultURL(vaultPath),
            let url = Self.resolve(note: note, in: vault, forWriting: true)
        else { return nil }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let final: String
        if append, let existing = try? String(contentsOf: url, encoding: .utf8), !existing.isEmpty {
            final = existing.hasSuffix("\n") ? existing + content : existing + "\n" + content
        } else {
            final = content
        }
        guard (try? final.write(to: url, atomically: true, encoding: .utf8)) != nil else {
            return nil
        }
        cache = nil  // the vault changed; force a re-scan on the next retrieval
        return Self.label(for: url, vault: vault)
    }

    /// Resolve a note argument (vault-relative path or bare title) to a URL inside the vault.
    private static func resolve(note: String, in vault: URL, forWriting: Bool) -> URL? {
        var rel = note.trimmingCharacters(in: .whitespaces)
        guard !rel.isEmpty else { return nil }
        while rel.hasPrefix("/") { rel.removeFirst() }
        if !rel.lowercased().hasSuffix(".md") { rel += ".md" }
        let candidate = vault.appendingPathComponent(rel).standardizedFileURL
        // Path-traversal guard: the resolved note must stay inside the vault.
        let root = vault.path.hasSuffix("/") ? vault.path : vault.path + "/"
        guard candidate.path.hasPrefix(root) else { return nil }
        if forWriting { return candidate }
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        // Fall back to a basename match (Obsidian notes are commonly referenced by title alone).
        let base = (rel as NSString).lastPathComponent.lowercased()
        return markdownFiles(in: vault).first { $0.lastPathComponent.lowercased() == base }
    }
}
