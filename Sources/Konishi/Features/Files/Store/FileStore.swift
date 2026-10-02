import Foundation

/// Lists and manages files the agent creates in each conversation's workspace.
struct FileStore {
    enum WorkspacePathError: LocalizedError {
        case empty
        case absolute
        case outsideWorkspace
        case symbolicLink

        var errorDescription: String? {
            switch self {
            case .empty: "A workspace-relative path is required."
            case .absolute: "Use a workspace-relative path, not an absolute path."
            case .outsideWorkspace: "The path escapes this conversation's workspace."
            case .symbolicLink: "Workspace file operations do not follow symbolic links."
            }
        }
    }

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

    func resolveWorkspacePath(_ path: String, in workspace: URL) throws -> URL {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.contains("\0") else { throw WorkspacePathError.empty }
        guard !(path as NSString).isAbsolutePath, !path.hasPrefix("~") else {
            throw WorkspacePathError.absolute
        }

        let root = workspace.standardizedFileURL.resolvingSymlinksInPath()
        let destination = root.appendingPathComponent(path).standardizedFileURL
        guard destination.path.hasPrefix(root.path + "/") else {
            throw WorkspacePathError.outsideWorkspace
        }

        var componentURL = root
        for component in path.split(separator: "/") {
            componentURL.appendPathComponent(String(component))
            guard FileManager.default.fileExists(atPath: componentURL.path) else { continue }
            let resolved = componentURL.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(root.path + "/") else {
                throw WorkspacePathError.outsideWorkspace
            }
            let values = try? componentURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values?.isSymbolicLink == true { throw WorkspacePathError.symbolicLink }
        }
        return destination
    }

    @discardableResult
    func write(path: String, content: String, in workspace: URL) throws -> URL {
        let destination = try resolveWorkspacePath(path, in: workspace)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: destination, atomically: true, encoding: .utf8)
        return destination
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
