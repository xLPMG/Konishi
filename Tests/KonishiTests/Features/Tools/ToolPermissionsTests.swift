import Foundation
import Testing

@testable import Konishi

@Suite("Tool permissions")
struct ToolPermissionsTests {
    @Test("every registered tool is classified")
    func registryIsCompletelyClassified() {
        for spec in Tools.all {
            let arguments: [String: JSONValue]
            switch spec.name {
            case "file_read", "file_write": arguments = ["path": .string("sample.md")]
            case "run_shell": arguments = ["command": .string("echo ready")]
            default: arguments = [:]
            }
            #expect((try? ToolPermissions.classify(
                toolName: spec.name, arguments: arguments, context: context())) != nil)
            #expect(!ToolPermissions.possibleCapabilities(for: spec.name).isEmpty || spec.name == "calculate")
        }
    }

    @Test("conversation rules override mode rules")
    func conversationRuleHasNarrowerLevel() {
        let context = context(
            modePolicy: PermissionPolicy(rules: [
                rule(.workspaceWrite, .any, .deny)
            ]),
            conversationRules: [rule(.workspaceWrite, .any, .allow)])

        #expect(ToolPermissions.evaluate([.init(.workspaceWrite)], context: context).verdict == .allow)
    }

    @Test("longest matching path prefix wins")
    func mostSpecificPathRuleWins() {
        let context = context(modePolicy: PermissionPolicy(rules: [
            rule(.workspaceWrite, .pathPrefix("/workspace"), .deny),
            rule(.workspaceWrite, .pathPrefix("/workspace/reports"), .allow)
        ]))

        let result = ToolPermissions.evaluate(
            [.init(.workspaceWrite, path: "/workspace/reports/annual.md")], context: context)
        #expect(result.verdict == .allow)
    }

    @Test("ties prefer deny, then allow, then ask")
    func tiedRulesUseDecisionPriority() {
        let context = context(modePolicy: PermissionPolicy(rules: [
            rule(.memoryWrite, .any, .ask),
            rule(.memoryWrite, .any, .allow),
            rule(.memoryWrite, .any, .deny)
        ]))

        #expect(ToolPermissions.evaluate([.init(.memoryWrite)], context: context).verdict == .deny)
    }

    @Test("defaults apply and path prefixes respect component boundaries")
    func defaultsAndPathBoundaries() {
        let context = context(modePolicy: PermissionPolicy(rules: [
            rule(.workspaceWrite, .pathPrefix("/workspace/reports"), .deny)
        ]))

        #expect(ToolPermissions.evaluate([.init(.workspaceRead)], context: context).verdict == .allow)
        #expect(ToolPermissions.evaluate(
            [.init(.workspaceWrite, path: "/workspace/reports-old/a.md")], context: context
        ).verdict == .allow)
        #expect(ToolPermissions.evaluate(
            [.init(.workspaceWrite, path: "/workspace/reports/a.md")], context: context
        ).verdict == .deny)
    }

    @Test("one denied or asked effect controls a mixed-effect call")
    func mixedEffectResolution() {
        let askContext = context(modePolicy: PermissionPolicy(rules: [
            rule(.memoryWrite, .any, .ask)
        ]))
        let ask = ToolPermissions.evaluate(
            [.init(.workspaceRead), .init(.memoryWrite)], context: askContext)
        #expect(ask.verdict == .ask)

        let denyContext = context(modePolicy: PermissionPolicy(rules: [
            rule(.memoryWrite, .any, .deny)
        ]))
        let deny = ToolPermissions.evaluate(
            [.init(.workspaceRead), .init(.memoryWrite)], context: denyContext)
        #expect(deny.verdict == .deny)
    }

    @Test("unknown tools ask and unattended asks become denials")
    func unknownAndUnattendedCallsFailClosed() {
        let interactive = ToolPermissions.evaluate(toolName: "not_a_tool", arguments: [:], context: context())
        #expect(interactive.verdict == .ask)

        let unattendedContext = context(
            surface: .unattended,
            modePolicy: PermissionPolicy(rules: [rule(.memoryWrite, .any, .ask)]))
        let unattended = ToolPermissions.evaluate(
            toolName: "memory_write", arguments: [:], context: unattendedContext)
        #expect(unattended.verdict == .deny)
        #expect(unattended.explanation?.contains("needs permission") == true)
    }

    @Test("unattended visibility hides tools without an allowed capability")
    func unattendedVisibilityUsesPermissions() {
        let enabled: Set<String> = ["file_write", "python_exec", "ask_multiple_choice", "memory_write"]
        let context = context(
            enabledTools: enabled,
            surface: .unattended,
            modePolicy: PermissionPolicy(rules: [rule(.memoryWrite, .any, .allow)]))

        #expect(Set(ToolPermissions.visibleTools(context: context).map(\.name)) == ["file_write", "memory_write"])
    }

    @Test("master, mode-tool, and persona gates control visibility")
    func visibilityGatesApply() {
        let allTools = Set(Tools.all.map(\.name))
        let masterOff = ToolPermissionContext(
            mode: .chat, workspace: URL(fileURLWithPath: "/workspace"),
            toolsEnabled: false, enabledTools: allTools, vaultAccessEnabled: true)
        #expect(ToolPermissions.visibleTools(context: masterOff).isEmpty)

        let modeDisabled = ToolPermissionContext(
            mode: .chat, workspace: URL(fileURLWithPath: "/workspace"),
            enabledTools: ["memory_list"], vaultAccessEnabled: false)
        let visible = Set(ToolPermissions.visibleTools(context: modeDisabled).map(\.name))
        #expect(visible == ["memory_list"])
        #expect(visible.isDisjoint(with: Tools.vaultToolNames))
    }

    @Test("unattended guidance lists permitted capabilities and refusal behavior")
    func unattendedGuidanceIsExplicit() {
        let context = context(enabledTools: ["file_write"], surface: .unattended)
        let guidance = ToolPermissions.unattendedGuidance(context: context)

        #expect(guidance.contains("Write workspace"))
        #expect(guidance.contains("Do not retry the same call"))
    }

    @Test("remembered path rules default to the containing folder")
    func rememberedRulesUseNarrowFolderScope() throws {
        let rules = try #require(ToolPermissions.allowRules(
            for: [
                .init(.workspaceWrite, path: "/workspace/reports/draft.md"),
                .init(.memoryWrite)
            ],
            workspace: URL(fileURLWithPath: "/workspace"),
            scopeChoice: .containingFolder))

        #expect(rules.contains {
            $0.capability == .workspaceWrite && $0.scope == .pathPrefix("/workspace/reports")
        })
        #expect(rules.contains { $0.capability == .memoryWrite && $0.scope == .any })
    }

    @Test("protected paths cannot produce remembered allow rules")
    func protectedPathHasNoRememberedRule() {
        let protected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/secret").path
        let rules = ToolPermissions.allowRules(
            for: [.init(.externalWrite, path: protected)],
            workspace: URL(fileURLWithPath: "/workspace"),
            scopeChoice: .anywhere)

        #expect(rules == nil)
    }

    @Test("protected locations downgrade allows but preserve denies")
    func protectedLocationOverridesAllow() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let protected = home.appendingPathComponent(".config/secret").path
        let allowed = context(modePolicy: PermissionPolicy(rules: [
            rule(.externalWrite, .any, .allow)
        ]))
        let ask = ToolPermissions.evaluate([.init(.externalWrite, path: protected)], context: allowed)
        #expect(ask.verdict == .ask)
        #expect(ask.source == .protectedLocation("Home dot-files and dot-folders are protected."))

        let denied = context(modePolicy: PermissionPolicy(rules: [
            rule(.externalWrite, .any, .deny)
        ]))
        #expect(ToolPermissions.evaluate([.init(.externalWrite, path: protected)], context: denied).verdict == .deny)
    }

    @Test("shell allowlist accepts simple commands only")
    func shellAllowlistClassification() {
        let allowlist: Set<String> = ["git", "find"]
        #expect(ToolPermissions.isShellAllowlisted("git status", allowlist: allowlist))
        #expect(!ToolPermissions.isShellAllowlisted("git status; rm -rf ~", allowlist: allowlist))
        #expect(!ToolPermissions.isShellAllowlisted("find . -delete", allowlist: allowlist))
    }

    @Test("shell calls map to allowlisted or code-execution capability")
    func shellCallsMapToCapabilities() throws {
        let context = context()
        let allowlistedResult = try ToolPermissions.classify(
            toolName: "run_shell", arguments: ["command": .string("git status")],
            context: ToolPermissionContext(
                mode: .chat, workspace: URL(fileURLWithPath: "/workspace"), shellAllowlist: ["git"]))
        let arbitraryResult = try ToolPermissions.classify(
            toolName: "run_shell", arguments: ["command": .string("git status; rm -rf ~")],
            context: context)
        let allowlisted = try #require(allowlistedResult)
        let arbitrary = try #require(arbitraryResult)

        #expect(allowlisted.first?.capability == .shellAllowlisted)
        #expect(arbitrary.first?.capability == .codeExecution)
    }

    @Test("permission policy round-trips and tolerates missing policy rules")
    func permissionPolicyRoundTrips() throws {
        let policy = PermissionPolicy(rules: [rule(.workspaceWrite, .any, .allow)])
        let decoded = try JSONDecoder().decode(PermissionPolicy.self, from: JSONEncoder().encode(policy))
        let empty = try JSONDecoder().decode(PermissionPolicy.self, from: Data("{}".utf8))
        #expect(decoded == policy)
        #expect(empty.rules.isEmpty)
    }

    private func context(
        enabledTools: Set<String> = Set(Tools.all.map(\.name)),
        surface: PermissionSurface = .interactive,
        modePolicy: PermissionPolicy = PermissionPolicy(),
        conversationRules: [PermissionRule] = []
    ) -> ToolPermissionContext {
        ToolPermissionContext(
            mode: .chat, workspace: URL(fileURLWithPath: "/workspace"),
            enabledTools: enabledTools, surface: surface, modePolicy: modePolicy,
            conversationRules: conversationRules)
    }

    private func rule(
        _ capability: Capability, _ scope: PermissionScope, _ decision: PermissionDecision
    ) -> PermissionRule {
        PermissionRule(capability: capability, scope: scope, decision: decision)
    }
}