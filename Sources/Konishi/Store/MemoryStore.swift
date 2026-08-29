import Foundation

/// Manages the Markdown memory files under `~/Konishi/memory/<scope>/`.
struct MemoryStore {
    static let globalScope = "global"

    struct File: Identifiable, Hashable {
        var id: String { scope + "/" + name }
        let scope: String
        let name: String
        let url: URL
    }

    func files(in scope: String) -> [File] {
        let dir = Paths.memoryScope(scope)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents
            .filter { $0.pathExtension.lowercased() == "md" }
            .map { File(scope: scope, name: $0.lastPathComponent, url: $0) }
            .sorted { $0.name < $1.name }
    }

    func read(_ file: File) -> String {
        (try? String(contentsOf: file.url, encoding: .utf8)) ?? ""
    }

    func write(scope: String, name: String, content: String) {
        let fileName = name.hasSuffix(".md") ? name : name + ".md"
        let url = Paths.memoryScope(scope).appendingPathComponent(fileName)
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    func append(scope: String, name: String, content: String) {
        let existing = read(File(scope: scope, name: name, url: Paths.memoryScope(scope).appendingPathComponent(name)))
        let separator = existing.isEmpty ? "" : "\n\n"
        write(scope: scope, name: name, content: existing + separator + content)
    }

    func delete(_ file: File) {
        try? FileManager.default.removeItem(at: file.url)
    }

    func delete(scope: String, name: String) {
        let url = Paths.memoryScope(scope).appendingPathComponent(name)
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
                let mtime = (try? file.url.resourceValues(forKeys: [.contentModificationDateKey])
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
        let root = Paths.memoryBackup(Self.backupStamp())
        var copied = false
        for scope in scopes {
            let scopeFiles = files(in: scope)
            guard !scopeFiles.isEmpty else { continue }
            let dir = root.appendingPathComponent(scope, isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for file in scopeFiles {
                try? fm.copyItem(at: file.url, to: dir.appendingPathComponent(file.name))
                copied = true
            }
        }
        return copied ? root : nil
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
}
