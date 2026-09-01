import Foundation
import Testing

@testable import Konishi

@Suite("PersonaStore")
struct PersonaStoreTests {

    /// Fresh temp file per test so tests never touch real app data or race each other.
    private func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("personas-\(UUID().uuidString).json")
    }

    @Test("starts with defaults when no file exists")
    func startsWithDefaults() {
        let store = PersonaStore(fileURL: tempFileURL())
        #expect(!store.personas.isEmpty)
        // Persona.defaults generates a fresh UUID per access (id defaults to UUID()),
        // so compare on names rather than full equality — ids are never meant to match.
        #expect(store.personas.map(\.name) == Persona.defaults.map(\.name))
    }

    @Test("addPersona appends and persists to disk")
    func addPersonaPersists() {
        let url = tempFileURL()
        let store = PersonaStore(fileURL: url)
        let countBefore = store.personas.count

        store.addPersona()
        Persistence.ioQueue.sync {}  // flush the async write before reading it back

        #expect(store.personas.count == countBefore + 1)
        #expect(store.personas.last?.name == "New Persona")

        // A second store reading the same file should see the persisted change.
        let reloaded = PersonaStore(fileURL: url)
        #expect(reloaded.personas.count == countBefore + 1)
    }

    @Test("updatePersona edits the matching persona in place")
    func updatePersonaEdits() {
        let store = PersonaStore(fileURL: tempFileURL())
        var first = store.personas[0]
        first.name = "Renamed"

        store.updatePersona(first)

        #expect(store.personas[0].name == "Renamed")
    }

    @Test("deletePersona removes it and returns a fallback id")
    func deletePersonaReturnsFallback() {
        let store = PersonaStore(fileURL: tempFileURL())
        store.addPersona()  // ensure 2+, since deletePersona refuses to empty the list
        let target = store.personas[0]

        let fallback = store.deletePersona(target.id)

        #expect(fallback != nil)
        #expect(!store.personas.contains { $0.id == target.id })
    }

    @Test("deletePersona refuses to remove the last remaining persona")
    func deletePersonaKeepsAtLeastOne() {
        let store = PersonaStore(fileURL: tempFileURL())
        while store.personas.count > 1 {
            _ = store.deletePersona(store.personas[0].id)
        }
        let lastID = store.personas[0].id

        let fallback = store.deletePersona(lastID)

        #expect(fallback == nil)
        #expect(store.personas.count == 1)
    }
}
