import Foundation
import Testing

@testable import Konishi

@Suite("Chat model selection")
@MainActor
struct ModelSelectionTests {
    @Test("starts with no selected model")
    func startsUnset() {
        let settings = AppSettings(defaults: makeDefaults())

        #expect(settings.model.isEmpty)
    }

    @Test("selects the only model advertised by the endpoint")
    func selectsOnlyAvailableModel() {
        let settings = makeSettings(model: "old-model")

        settings.reconcileModelSelection(availableModelIDs: [" new-model "])

        #expect(settings.model == "new-model")
    }

    @Test("keeps a valid selection when the endpoint offers multiple models")
    func keepsValidSelection() {
        let settings = makeSettings(model: "model-b")

        settings.reconcileModelSelection(availableModelIDs: ["model-a", "model-b"])

        #expect(settings.model == "model-b")
    }

    @Test("clears unavailable selections when the endpoint changes or is offline")
    func clearsStaleSelection() {
        let settings = makeSettings(model: "old-model")

        settings.reconcileModelSelection(availableModelIDs: ["model-a", "model-b"])
        #expect(settings.model.isEmpty)

        settings.model = "model-a"
        settings.reconcileModelSelection(availableModelIDs: [])
        #expect(settings.model.isEmpty)
    }

    private func makeSettings(model: String) -> AppSettings {
        let defaults = makeDefaults()
        defaults.set(model, forKey: "konishi.model")
        return AppSettings(defaults: defaults)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "Konishi-ModelSelection-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
