import Foundation

/// Lists and manages files the agent creates under `~/Konishi/files/<persona scope>/`.
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

    /// Files in a conversation's working directory, newest first.
    func entries(conversation id: UUID) -> [Entry] {
        let dir = Paths.conversationFiles(id)
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        )) ?? []
        return contents.map { url in
            let values = try? url.resourceValues(forKeys: keys)
            return Entry(
                name: url.lastPathComponent,
                url: url,
                size: values?.fileSize ?? 0,
                modified: values?.contentModificationDate ?? .distantPast,
                isDirectory: values?.isDirectory ?? false
            )
        }
        .sorted { $0.modified > $1.modified }
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
