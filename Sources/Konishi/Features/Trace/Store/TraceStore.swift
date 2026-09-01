import Foundation

@MainActor
@Observable
final class TraceStore {

    private let traceFileURL: (UUID) -> URL
    /// Live request/response trace per conversation (in-memory, cleared with the chat).
    var traces: [UUID: [TraceEntry]] = [:]
    /// Conversations whose persisted trace has already been pulled into `traces` this session.
    private var loadedTraceIDs: Set<UUID> = []
    /// Debounced per-conversation trace writers.
    private var traceSaveTasks: [UUID: Task<Void, Never>] = [:]

    init(traceFileURL: @escaping (UUID) -> URL = Paths.traceFile) {
        self.traceFileURL = traceFileURL
    }

    nonisolated private static func saveTrace(entries: [TraceEntry], to url: URL) {
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? Persistence.encoder.encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    nonisolated private static func loadTrace(from url: URL) -> [TraceEntry] {
        guard let data = try? Data(contentsOf: url),
            let decoded = try? Persistence.decoder.decode([TraceEntry].self, from: data)
        else { return [] }
        return decoded
    }

    func deleteTraceFile(conversationID: UUID) {
        traces[conversationID] = nil
        let url = traceFileURL(conversationID)
        try? FileManager.default.removeItem(at: url)
        loadedTraceIDs.remove(conversationID)
    }

    func clearTrace(conversationID: UUID) {
        traces[conversationID] = nil
        deleteTraceFile(conversationID: conversationID)
    }

    /// Load a conversation's trace from disk on first view (traces from earlier sessions).
    func ensureTraceLoaded(conversationID: UUID) {
        guard loadedTraceIDs.insert(conversationID).inserted else { return }
        guard traces[conversationID] == nil else { return }
        let disk = Self.loadTrace(from: traceFileURL(conversationID))
        if !disk.isEmpty { traces[conversationID] = disk }
    }

    func trace(
        conversationID: UUID, kind: TraceEntry.Kind, text: String, saveTraces: Bool,
        detail: String? = nil
    ) {
        ensureTraceLoaded(conversationID: conversationID)  // merge with a prior session's trace before appending
        traces[conversationID, default: []].append(
            TraceEntry(kind: kind, text: text, detail: detail))
        if let count = traces[conversationID]?.count, count > 600 {
            traces[conversationID]?.removeFirst(count - 600)
        }
        if saveTraces { scheduleTraceSave(conversationID: conversationID) }
    }

    /// Persist the trace shortly after the last event so streaming bursts coalesce into one write.
    private func scheduleTraceSave(conversationID: UUID) {
        traceSaveTasks[conversationID]?.cancel()
        let snapshot = traces[conversationID] ?? []
        let url = traceFileURL(conversationID)
        traceSaveTasks[conversationID] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            await Task.detached {
                Self.saveTrace(entries: snapshot, to: url)
            }.value
            self?.traceSaveTasks[conversationID] = nil
        }
    }

    func cancelTraceSave(conversationID: UUID) {
        traceSaveTasks[conversationID]?.cancel()
        traceSaveTasks[conversationID] = nil
    }
}
