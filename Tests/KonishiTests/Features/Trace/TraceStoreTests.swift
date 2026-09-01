import Foundation
import Testing

@testable import Konishi

@Suite("TraceStore")
@MainActor
struct TraceStoreTests {

    private func withStore(_ body: (TraceStore, UUID, URL) async throws -> Void) async rethrows {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("trace-store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = TraceStore { id in directory.appendingPathComponent("\(id.uuidString).json") }
        let conversationID = UUID()
        try await body(
            store, conversationID,
            directory.appendingPathComponent("\(conversationID.uuidString).json"))
    }

    @Test("appends entries with their payload")
    func appendsEntries() async throws {
        try await withStore { store, conversationID, _ in
            store.trace(
                conversationID: conversationID, kind: .request, text: "request", saveTraces: false,
                detail: "full request")
            store.trace(
                conversationID: conversationID, kind: .result, text: "result", saveTraces: false)

            let entries = try #require(store.traces[conversationID])
            #expect(entries.count == 2)
            #expect(entries[0].kind == .request)
            #expect(entries[0].text == "request")
            #expect(entries[0].detail == "full request")
            #expect(entries[1].kind == .result)
            #expect(entries[1].text == "result")
            #expect(entries[1].detail == nil)
        }
    }

    @Test("loads an existing trace once before appending")
    func loadsAndMergesTrace() async throws {
        try await withStore { store, conversationID, url in
            let prior = TraceEntry(kind: .info, text: "from disk")
            try Persistence.encoder.encode([prior]).write(to: url, options: .atomic)

            store.trace(
                conversationID: conversationID, kind: .result, text: "live", saveTraces: false)

            let entries = try #require(store.traces[conversationID])
            #expect(entries.map(\.text) == ["from disk", "live"])
        }
    }

    @Test("retains the most recent 600 entries")
    func capsTraceLength() async throws {
        try await withStore { store, conversationID, _ in
            for number in 0...600 {
                store.trace(
                    conversationID: conversationID, kind: .token, text: "\(number)",
                    saveTraces: false)
            }

            let entries = try #require(store.traces[conversationID])
            #expect(entries.count == 600)
            #expect(entries.first?.text == "1")
            #expect(entries.last?.text == "600")
        }
    }

    @Test("persists a debounced snapshot")
    func savesTrace() async throws {
        try await withStore { store, conversationID, url in
            store.trace(
                conversationID: conversationID, kind: .usage, text: "usage", saveTraces: true)
            try await Task.sleep(for: .milliseconds(1_400))

            let data = try Data(contentsOf: url)
            let entries = try Persistence.decoder.decode([TraceEntry].self, from: data)
            #expect(entries.map(\.text) == ["usage"])
        }
    }

    @Test("clear removes the in-memory and persisted trace")
    func clearTraceRemovesEverything() async throws {
        try await withStore { store, conversationID, url in
            try Data("[]".utf8).write(to: url)
            store.ensureTraceLoaded(conversationID: conversationID)

            store.clearTrace(conversationID: conversationID)

            #expect(store.traces[conversationID] == nil)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("deleteTraceFile removes the in-memory and persisted trace")
    func deleteTraceFileRemovesEverything() async throws {
        try await withStore { store, conversationID, url in
            store.trace(conversationID: conversationID, kind: .info, text: "live", saveTraces: false)
            try Data("[]".utf8).write(to: url)

            store.deleteTraceFile(conversationID: conversationID)

            #expect(store.traces[conversationID] == nil)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }
}
