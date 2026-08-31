import Foundation

/// A large attached document, chunked and persisted per conversation for retrieval (RAG).
struct StoredDocument: Codable, Identifiable, Sendable, Equatable {
    var id = UUID()
    var name: String
    var chunks: [String]
    var addedAt = Date()

    var charCount: Int { chunks.reduce(0) { $0 + $1.count } }
}

/// Persists retrieval documents under `~/Konishi/documents/<conversationID>/<docID>.json`.
struct DocumentStore {
    private func dir(_ conversationID: UUID) -> URL {
        let url = Paths.documents.appendingPathComponent(conversationID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func documents(for conversationID: UUID) -> [StoredDocument] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir(conversationID), includingPropertiesForKeys: nil
        )) ?? []
        return contents
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(StoredDocument.self, from: Data(contentsOf: $0)) }
            .sorted { $0.addedAt < $1.addedAt }
    }

    @discardableResult
    func add(name: String, text: String, conversationID: UUID) -> StoredDocument {
        let doc = StoredDocument(name: name, chunks: Self.chunks(text))
        if let data = try? JSONEncoder().encode(doc) {
            try? data.write(to: dir(conversationID).appendingPathComponent("\(doc.id.uuidString).json"))
        }
        return doc
    }

    func delete(id: UUID, conversationID: UUID) {
        try? FileManager.default.removeItem(at: dir(conversationID).appendingPathComponent("\(id.uuidString).json"))
    }

    func deleteAll(conversationID: UUID) {
        try? FileManager.default.removeItem(at: dir(conversationID))
    }

    /// Splits text into retrieval-sized passages, packing paragraphs toward `target` chars.
    static func chunks(_ text: String, target: Int = 1000, maxLen: Int = 2000) -> [String] {
        var chunks: [String] = []
        var current = ""
        for para in text.components(separatedBy: "\n\n") {
            let piece = para.trimmingCharacters(in: .whitespacesAndNewlines)
            if piece.isEmpty { continue }
            if current.isEmpty {
                current = piece
            } else if current.count + piece.count + 2 <= target {
                current += "\n\n" + piece
            } else {
                chunks.append(current)
                current = piece
            }
            while current.count > maxLen {
                chunks.append(String(current.prefix(maxLen)))
                current = String(current.dropFirst(maxLen))
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
