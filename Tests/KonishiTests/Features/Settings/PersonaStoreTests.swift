import Foundation
import Testing

@testable import Konishi

@Suite("PersonaStore")
@MainActor
struct PersonaStoreTests {

    /// Fresh temp file per test so tests never touch real app data or race each other.
    nonisolated private func tempFileURL() -> URL {
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

    @Test("stable system prompt treats retrieved content as reference data")
    func stablePromptMarksRetrievedContentAsReference() {
        let store = PersonaStore(fileURL: tempFileURL())
        let prompt = store.stableSystemPrompt(
            persona: store.personas[0], injectDateContext: false, mode: .chat)

        #expect(prompt.contains(PersonaStore.contextSourceInstruction))
        #expect(prompt.contains("</konishi_actions>"))
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
        let url = tempFileURL()
        let store = PersonaStore(fileURL: url)
        var first = store.personas[0]
        first.name = "Renamed"

        store.updatePersona(first)
        Persistence.ioQueue.sync {}

        #expect(store.personas[0].name == "Renamed")
        #expect(PersonaStore(fileURL: url).personas[0].name == "Renamed")
    }

    @Test("deletePersona removes it and returns a fallback id")
    func deletePersonaReturnsFallback() {
        let url = tempFileURL()
        let store = PersonaStore(fileURL: url)
        store.addPersona()  // ensure 2+, since deletePersona refuses to empty the list
        let target = store.personas[0]

        let fallback = store.deletePersona(target.id)
        Persistence.ioQueue.sync {}

        #expect(fallback != nil)
        #expect(!store.personas.contains { $0.id == target.id })
        #expect(!PersonaStore(fileURL: url).personas.contains { $0.id == target.id })
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

    @Test("deletePersona does nothing for an unknown id")
    func deletePersonaRejectsUnknownID() {
        let store = PersonaStore(fileURL: tempFileURL())
        let original = store.personas

        let fallback = store.deletePersona(UUID())

        #expect(fallback == nil)
        #expect(store.personas == original)
    }
}
