import Foundation

enum PermissionPolicyMigration {
    static let excludedTools: Set<String> = [
        "file_write", "calendar_create_event", "calendar_update_event",
        "reminder_create", "reminder_update",
    ]
    private static let legacyAutoApprovalDefaults: Set<String> = [
        "memory_list", "memory_read", "conversation_search", "conversation_list",
        "conversation_read", "web_search", "web_fetch", "web_research", "calculate",
        "calendar_events", "reminders_list", "vault_search",
        "vault_read", "vault_list",
    ]

    static func legacyAutoApprovedDefaults(for _: AppMode) -> Set<String> { legacyAutoApprovalDefaults }

    static func migrate(
        mode: AppMode, legacyAutoApprovedTools: Set<String>?
    ) -> PermissionPolicy {
        guard let legacyAutoApprovedTools else { return PermissionPolicy() }

        let controllableTools = Tools.all.filter { !excludedTools.contains($0.name) }
        let rules = Capability.allCases.compactMap { capability -> PermissionRule? in
            guard capability != .userInput,
                  capability.defaultDecision(for: mode) != .allow
            else { return nil }

            let mappedTools = controllableTools.filter {
                ToolPermissions.possibleCapabilities(for: $0.name).contains(capability)
            }
            guard !mappedTools.isEmpty,
                  mappedTools.allSatisfy({ legacyAutoApprovedTools.contains($0.name) })
            else { return nil }

            return PermissionRule(capability: capability, decision: .allow)
        }
        return PermissionPolicy(rules: rules)
    }
}