import Foundation

/// Scans common on-disk locations for downloaded models (for the "--model" path).
enum LocalModels {
    struct Entry: Identifiable, Hashable, Sendable {
        var id: String { path }
        let name: String
        let path: String
    }

    static func discover() -> [Entry] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [
            home.appendingPathComponent(".lmstudio/models"),
            home.appendingPathComponent(".cache/lm-studio/models"),
            home.appendingPathComponent(".cache/huggingface/hub")
        ]
        var found: [Entry] = []
        for root in roots {
            found.append(contentsOf: scan(root))
        }
        // De-dupe by path, keep sorted by name.
        var seen = Set<String>()
        return found
            .filter { seen.insert($0.path).inserted }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private static func scan(_ root: URL) -> [Entry] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var entries: [Entry] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let hasConfig = fm.fileExists(atPath: url.appendingPathComponent("config.json").path)
            let hasWeights = ((try? fm.contentsOfDirectory(atPath: url.path)) ?? [])
                .contains { $0.hasSuffix(".safetensors") || $0.hasSuffix(".gguf") }
            guard hasConfig || hasWeights else { continue }
            let name = url.path
                .replacingOccurrences(of: root.path + "/", with: "")
                .replacingOccurrences(of: "models--", with: "")
                .replacingOccurrences(of: "--", with: "/")
            entries.append(Entry(name: name, path: url.path))
            enumerator.skipDescendants()
        }
        return entries
    }
}
