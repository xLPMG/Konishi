import Foundation
import Testing

@testable import Konishi

@Suite("Permission policy migration")
@MainActor
struct PermissionPolicyMigrationTests {
    @Test("migrates only complete user-controlled approvals")
    func migratesCompleteCapabilityApproval() {
        let policy = PermissionPolicyMigration.migrate(
            mode: .chat,
            legacyAutoApprovedTools: [
                "memory_write", "memory_append", "file_write", "calendar_create_event",
                "calendar_update_event", "reminder_create", "reminder_update"
            ])

        #expect(policy.rules.map(\.capability) == [.memoryWrite])
        #expect(policy.rules.first?.decision == .allow)
    }

    @Test("does not migrate unset or incomplete legacy auto-approve sets")
    func missingOrIncompleteLegacySetsStayAtDefaults() {
        #expect(PermissionPolicyMigration.migrate(mode: .chat, legacyAutoApprovedTools: nil).rules.isEmpty)
        #expect(PermissionPolicyMigration.migrate(
            mode: .chat, legacyAutoApprovedTools: ["memory_write"]).rules.isEmpty)
    }

    @Test("preserves Chat and Voice settings while disabling Learn tools")
    func migratesMasterSwitches() {
        let defaults = makeDefaults()
        defaults.set(6, forKey: "konishi.settingsVersion")
        defaults.set(true, forKey: "konishi.toolsEnabled")

        let settings = AppSettings(defaults: defaults)

        #expect(settings.toolsEnabled(for: .chat))
        #expect(settings.toolsEnabled(for: .conversational))
        #expect(!settings.toolsEnabled(for: .language))
        #expect(settings.enabledTools(for: .language).isEmpty)
        #expect(defaults.integer(forKey: "konishi.settingsVersion") == 8)
    }

    @Test("preserves the pre-v7 default-off master when its legacy key is absent")
    func preservesLegacyDefaultOffMaster() {
        let defaults = makeDefaults()
        defaults.set(6, forKey: "konishi.settingsVersion")

        let settings = AppSettings(defaults: defaults)

        #expect(!settings.toolsEnabled(for: .chat))
        #expect(!settings.toolsEnabled(for: .conversational))
        #expect(!settings.toolsEnabled(for: .language))
    }

    @Test("persists migrated policy JSON per mode")
    func persistsPolicyJSON() throws {
        let defaults = makeDefaults()
        defaults.set(6, forKey: "konishi.settingsVersion")
        defaults.set(false, forKey: "konishi.toolsEnabled")
        defaults.set(["memory_write", "memory_append"], forKey: "konishi.autoApprove.chat")

        let settings = AppSettings(defaults: defaults)
        let policy = settings.permissionPolicy(for: .chat)
        let saved = try #require(defaults.data(forKey: "konishi.permissionPolicy.chat"))
        let decoded = try JSONDecoder().decode(PermissionPolicy.self, from: saved)

        #expect(policy == decoded)
        #expect(policy.rules.map(\.capability) == [.memoryWrite])
        #expect(!settings.toolsEnabled(for: .chat))
        #expect(!settings.toolsEnabled(for: .conversational))
        #expect(!settings.toolsEnabled(for: .language))
    }

    @Test("version 7 ignores stale legacy master and auto-approve keys")
    func versionSevenIgnoresLegacyPermissionKeys() {
        let defaults = makeDefaults()
        defaults.set(7, forKey: "konishi.settingsVersion")
        defaults.set(false, forKey: "konishi.toolsEnabled")
        defaults.set(["memory_write", "memory_append"], forKey: "konishi.autoApprove.chat")
        defaults.set("git\n", forKey: "konishi.shellAutoApproveCommands.chat")

        let settings = AppSettings(defaults: defaults)

        #expect(settings.toolsEnabled(for: .chat))
        #expect(settings.permissionPolicy(for: .chat).rules.isEmpty)
        #expect(settings.shellAllowlist(for: .chat) == "git\n")
        #expect(defaults.stringArray(forKey: "konishi.autoApprove.chat") == ["memory_write", "memory_append"])
    }

    @Test("fresh Autopilot defaults allow workspace file writes")
    func freshAutopilotCanWriteWorkspaceFiles() {
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
        let suite = "Konishi-PermissionMigration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}