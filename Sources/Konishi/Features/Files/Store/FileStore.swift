import Foundation

/// Lists and manages files the agent creates in each conversation's workspace.
struct FileStore {
    struct Entry: Identifiable, Hashable {
        var id: String { url.path }
        let name: String
        let url: URL
        let size: Int
        let modified: Date
        let isDirectory: Bool

        var isImage: Bool {
            ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff"].contains(url.pathExtension.lowercased())
        }
    }

    func resolvePath(_ path: String, in workspace: URL, expectedResolvedPath: String? = nil) throws -> URL {
        let resolved = try PathScope.resolve(path, in: workspace).url
        if let expectedResolvedPath, !PathScope.pathsEqual(resolved.path, expectedResolvedPath) {
            throw PathScope.PathError.pathChanged
        }
        return resolved
    }

    func read(path: String, in workspace: URL, expectedResolvedPath: String? = nil) throws -> String {
        let initial = try resolvePath(path, in: workspace, expectedResolvedPath: expectedResolvedPath)
        let verified = try resolvePath(path, in: workspace, expectedResolvedPath: initial.path)
        return try String(contentsOf: verified, encoding: .utf8)
    }

    @discardableResult
    func write(
        path: String, content: String, in workspace: URL, expectedResolvedPath: String? = nil
    ) throws -> URL {
        let initial = try resolvePath(path, in: workspace, expectedResolvedPath: expectedResolvedPath)
        try FileManager.default.createDirectory(
            at: initial.deletingLastPathComponent(), withIntermediateDirectories: true)
        let verified = try resolvePath(path, in: workspace, expectedResolvedPath: initial.path)
        try content.write(to: verified, atomically: true, encoding: .utf8)
        return verified
    }

    /// Files in a conversation's working directory, newest first.
    func entries(conversation id: UUID) -> [Entry] {
        let dir = Paths.conversationFiles(id)
        let keys: Set<URLResourceKey> = [
            .fileSizeKey, .contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return [] }
        var entries: [Entry] = []
        while let url = enumerator.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            entries.append(Entry(
                name: String(url.path.dropFirst(dir.path.count + 1)),
                url: url,
                size: values?.fileSize ?? 0,
                modified: values?.contentModificationDate ?? .distantPast,
                isDirectory: values?.isDirectory ?? false
            ))
        }
        return entries.sorted { $0.modified > $1.modified }
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
