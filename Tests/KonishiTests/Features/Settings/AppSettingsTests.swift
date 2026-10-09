import Foundation
import Testing

@testable import Konishi

@Suite("Current app settings")
@MainActor
struct AppSettingsTests {
    @Test("preserves per-mode tool settings")
    func preservesPerModeToolSettings() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: "konishi.toolsEnabled.chat")
        defaults.set(["calculate"], forKey: "konishi.enabledTools.chat")

        let settings = AppSettings(defaults: defaults)

        #expect(!settings.toolsEnabled(for: .chat))
        #expect(settings.enabledTools(for: .chat) == ["calculate"])
        #expect(settings.toolsEnabled(for: .conversational))
        #expect(!settings.toolsEnabled(for: .language))
    }

    @Test("leaves the default chat model unset until selected")
    func defaultModelIsUnset() {
        let settings = AppSettings(defaults: makeDefaults())

        #expect(settings.model.isEmpty)
        #expect(settings.requestConfig(modelOverride: nil).model.isEmpty)
        #expect(settings.requestConfig(modelOverride: "  ").model.isEmpty)
        #expect(settings.requestConfig(modelOverride: " chosen-model ").model == "chosen-model")
    }

    @Test("fresh chat settings allow workspace file writes")
    func freshChatCanWriteWorkspaceFiles() {
        let settings = AppSettings(defaults: makeDefaults())
        let context = ToolPermissionContext(
            mode: .chat,
            workspace: URL(fileURLWithPath: "/workspace"),
            toolsEnabled: settings.toolsEnabled(for: .chat),
            enabledTools: settings.enabledTools(for: .chat),
            surface: .unattended)
        let evaluation = ToolPermissions.evaluate(
            toolName: "file_write",
            arguments: ["path": .string("draft.md"), "content": .string("text")],
            context: context)

        #expect(settings.toolsEnabled(for: .chat))
        #expect(ToolPermissions.visibleTools(context: context).contains { $0.name == "file_write" })
        #expect(evaluation.verdict == .allow)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "Konishi-AppSettings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}