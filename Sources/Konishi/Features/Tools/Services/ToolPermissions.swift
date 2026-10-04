import Foundation

enum ProtectedLocations {
    static let systemRoots = [
        "/System", "/Library", "/usr", "/bin", "/sbin", "/etc", "/private", "/Applications",
    ]

    static func reason(
        for path: String, workspace: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
        konishiRoot: URL = Paths.root
    ) -> String? {
        let canonicalPath = PathScope.canonicalPath(path)
        let homePath = PathScope.canonicalURL(home).path
        let workspacePath = PathScope.canonicalURL(workspace)
        let konishiPath = PathScope.canonicalURL(konishiRoot)

        if PathScope.path(canonicalPath, isWithin: homePath), canonicalPath != homePath {
            let remainder = String(canonicalPath.dropFirst(homePath.count)).split(separator: "/")
            if let first = remainder.first, first.hasPrefix(".") {
                return "Home dot-files and dot-folders are protected."
            }
            if let first = remainder.first, first.caseInsensitiveCompare("Library") == .orderedSame {
                return "~/Library is protected."
            }
        }

        if let root = systemRoots.first(where: { PathScope.path(canonicalPath, isWithin: $0) }) {
            return "\(root) is a protected system location."
        }

        if PathScope.contains(konishiPath, URL(fileURLWithPath: canonicalPath)),
           !PathScope.contains(workspacePath, URL(fileURLWithPath: canonicalPath))
        {
            return "Konishi data outside this conversation's Files folder is protected."
        }
        return nil
    }
}

struct PermissionEffect: Equatable, Sendable {
    let capability: Capability
    let path: String?

    init(_ capability: Capability, path: String? = nil) {
        self.capability = capability
        self.path = path.map(PathScope.canonicalPath)
    }
}

enum PermissionSource: Equatable, Sendable {
    case `default`
    case modeRule
    case conversationRule
    case protectedLocation(String)

    func label(for mode: AppMode) -> String {
        switch self {
        case .default: "default"
        case .modeRule: "\(mode.label) mode rule"
        case .conversationRule: "this conversation rule"
        case let .protectedLocation(reason): reason
        }
    }
}

struct EffectEvaluation: Equatable, Sendable {
    let effect: PermissionEffect
    let decision: PermissionDecision
    let source: PermissionSource
}

struct ToolPermissionEvaluation: Equatable, Sendable {
    let effects: [EffectEvaluation]
    let verdict: PermissionDecision
    let source: PermissionSource
    let explanation: String?
}

struct ToolPermissionContext: Sendable {
    let mode: AppMode
    let workspace: URL
    let toolsEnabled: Bool
    let enabledTools: Set<String>
    let vaultAccessEnabled: Bool
    let shellAllowlist: Set<String>
    let surface: PermissionSurface
    let modePolicy: PermissionPolicy
    let conversationRules: [PermissionRule]

    init(
        mode: AppMode, workspace: URL, toolsEnabled: Bool = true,
        enabledTools: Set<String> = Set(Tools.all.map(\.name)),
        vaultAccessEnabled: Bool = false, shellAllowlist: Set<String> = [],
        surface: PermissionSurface = .interactive, modePolicy: PermissionPolicy = PermissionPolicy(),
        conversationRules: [PermissionRule] = []
    ) {
        self.mode = mode
        self.workspace = workspace
        self.toolsEnabled = toolsEnabled
        self.enabledTools = enabledTools
        self.vaultAccessEnabled = vaultAccessEnabled
        self.shellAllowlist = shellAllowlist
        self.surface = surface
        self.modePolicy = modePolicy
        self.conversationRules = conversationRules
    }
}

enum ToolPermissions {
    static func allowRules(
        for effects: [PermissionEffect], workspace: URL, scopeChoice: PermissionRuleScopeChoice
    ) -> [PermissionRule]? {
        guard !effects.isEmpty else { return nil }
        var rules: [PermissionRule] = []
        for effect in effects {
            if let path = effect.path,
               ProtectedLocations.reason(for: path, workspace: workspace) != nil
            {
                return nil
            }
            let scope: PermissionScope
            if effect.path == nil || scopeChoice == .anywhere {
                scope = .any
            } else if let path = effect.path {
                scope = .pathPrefix(PathScope.canonicalPath(
                    URL(fileURLWithPath: path).deletingLastPathComponent().path))
            } else {
                continue
            }
            guard !rules.contains(where: { $0.capability == effect.capability && $0.scope == scope }) else {
                continue
            }
            rules.append(PermissionRule(capability: effect.capability, scope: scope, decision: .allow))
        }
        return rules.isEmpty ? nil : rules
    }

    static func classify(
        toolName: String, arguments: [String: JSONValue], context: ToolPermissionContext
    ) throws -> [PermissionEffect]? {
        switch toolName {
        case "memory_list", "memory_read": return [.init(.memoryRead)]
        case "memory_write", "memory_append": return [.init(.memoryWrite)]
        case "conversation_search", "conversation_list", "conversation_read": return [.init(.recallRead)]
        case "file_read":
            guard let path = string("path", in: arguments) else { return nil }
            let resolved = try PathScope.resolve(path, in: context.workspace)
            return [.init(resolved.isWithinWorkspace ? .workspaceRead : .externalRead, path: resolved.url.path)]
        case "file_write":
            guard let path = string("path", in: arguments) else { return nil }
            let resolved = try PathScope.resolve(path, in: context.workspace)
            return [.init(resolved.isWithinWorkspace ? .workspaceWrite : .externalWrite, path: resolved.url.path)]
        case "web_search", "web_fetch", "web_research": return [.init(.webAccess)]
        case "calculate", "end_conversation": return []
        case "python_exec": return [.init(.codeExecution)]
        case "run_shell":
            guard let command = string("command", in: arguments) else { return nil }
            return [
                .init(isShellAllowlisted(command, allowlist: context.shellAllowlist)
                    ? .shellAllowlisted : .codeExecution)
            ]
        case "calendar_events", "reminders_list": return [.init(.personalDataRead)]
        case "calendar_create_event", "calendar_update_event", "reminder_create", "reminder_update":
            return [.init(.personalDataWrite)]
        case "vault_search", "vault_read", "vault_list": return [.init(.vaultRead)]
        case "vault_write", "vault_append": return [.init(.vaultWrite)]
        default: return nil
        }
    }

    static func evaluate(
        toolName: String, arguments: [String: JSONValue], context: ToolPermissionContext
    ) -> ToolPermissionEvaluation {
        let effects: [PermissionEffect]
        do {
            guard let classified = try classify(
                toolName: toolName, arguments: arguments, context: context)
            else {
                let explanation = context.surface == .unattended
                    ? "Unknown tool `\(toolName)` has no classified capability. Do not retry it; report that it is unavailable."
                    : "Unknown or unclassifiable tool; permission is required."
                return ToolPermissionEvaluation(
                    effects: [], verdict: unattended(.ask, surface: context.surface),
                    source: .default, explanation: explanation
                )
            }
            effects = classified
        } catch {
            return ToolPermissionEvaluation(
                effects: [], verdict: .deny, source: .default,
                explanation: error.localizedDescription
            )
        }

        let decisions = effects.map { evaluate($0, context: context) }
        let rawVerdict: PermissionDecision
        if decisions.contains(where: { $0.decision == .deny }) {
            rawVerdict = .deny
        } else if decisions.contains(where: { $0.decision == .ask }) {
            rawVerdict = .ask
        } else {
            rawVerdict = .allow
        }
        let verdict = unattended(rawVerdict, surface: context.surface)
        let decidingEffect = decisions.first(where: { $0.decision == rawVerdict })
        let source = decidingEffect?.source ?? .default
        let explanation: String?
        if rawVerdict == .ask, context.surface == .unattended {
            let capability = decisions.first(where: { $0.decision == .ask })?.effect.capability.label ?? "This action"
            explanation = "\(capability) needs permission. Do not retry this call; adapt or report the block."
        } else if rawVerdict == .deny {
            let capabilities = decisions.filter { $0.decision == .deny }
                .map { $0.effect.capability.label }
            let affected = capabilities.isEmpty ? "the requested action" : capabilities.joined(separator: ", ")
            explanation = "Denied by policy: \(affected). Do not retry this call."
        } else {
            explanation = nil
        }
        return ToolPermissionEvaluation(
            effects: decisions, verdict: verdict, source: source, explanation: explanation)
    }

    static func evaluate(
        _ effects: [PermissionEffect], context: ToolPermissionContext
    ) -> ToolPermissionEvaluation {
        let decisions = effects.map { evaluate($0, context: context) }
        let rawVerdict: PermissionDecision
        if decisions.contains(where: { $0.decision == .deny }) {
            rawVerdict = .deny
        } else if decisions.contains(where: { $0.decision == .ask }) {
            rawVerdict = .ask
        } else {
            rawVerdict = .allow
        }
        return ToolPermissionEvaluation(
            effects: decisions, verdict: unattended(rawVerdict, surface: context.surface),
            source: decisions.first(where: { $0.decision == rawVerdict })?.source ?? .default,
            explanation: rawVerdict == .ask && context.surface == .unattended
                ? "A capability needs permission on the unattended surface."
                : nil
        )
    }

    static func visibleTools(context: ToolPermissionContext) -> [ToolSpec] {
        guard context.toolsEnabled else { return [] }
        return Tools.all.filter { spec in
            guard context.enabledTools.contains(spec.name),
                  context.vaultAccessEnabled || !Tools.vaultToolNames.contains(spec.name)
            else { return false }
            guard context.surface == .unattended else { return true }
            return possibleCapabilities(for: spec.name).contains {
                mayAllow($0, context: context)
            }
        }
    }

    static func allowedCapabilities(context: ToolPermissionContext) -> [Capability] {
        let capabilities = visibleTools(context: context).flatMap { possibleCapabilities(for: $0.name) }
        return Set(capabilities.filter { mayAllow($0, context: context) })
            .sorted { $0.rawValue < $1.rawValue }
    }

    static func unattendedGuidance(context: ToolPermissionContext) -> String {
        let capabilities = allowedCapabilities(context: context).map(\.label)
        let names = visibleTools(context: context).map(\.name)
        let allowedText = capabilities.isEmpty ? "none" : capabilities.joined(separator: ", ")
        let toolsText = names.isEmpty ? "none" : names.joined(separator: ", ")
        return """
            # Unattended permissions
            Allowed capabilities: \(allowedText).
            Available tools: \(toolsText).
            A denied call explains what was blocked. Do not retry the same call; adapt using allowed tools or report what needs human permission.
            """
    }

    static func possibleCapabilities(for toolName: String) -> [Capability] {
        switch toolName {
        case "file_read": [.workspaceRead, .externalRead]
        case "file_write": [.workspaceWrite, .externalWrite]
        case "run_shell": [.shellAllowlisted, .codeExecution]
        case "memory_list", "memory_read": [.memoryRead]
        case "memory_write", "memory_append": [.memoryWrite]
        case "conversation_search", "conversation_list", "conversation_read": [.recallRead]
        case "web_search", "web_fetch", "web_research": [.webAccess]
        case "calculate", "end_conversation": []
        case "python_exec": [.codeExecution]
        case "calendar_events", "reminders_list": [.personalDataRead]
        case "calendar_create_event", "calendar_update_event", "reminder_create", "reminder_update": [.personalDataWrite]
        case "vault_search", "vault_read", "vault_list": [.vaultRead]
        case "vault_write", "vault_append": [.vaultWrite]
        default: []
        }
    }

    static func isShellAllowlisted(_ command: String, allowlist: Set<String>) -> Bool {
        guard !allowlist.isEmpty else { return false }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let unsafeSyntax = CharacterSet(charactersIn: "\n\r;&|<>`$()")
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: unsafeSyntax) == nil,
              let first = trimmed.split(whereSeparator: \.isWhitespace).first else { return false }
        let executable = String(first)
        let validName = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._/+"))
        guard executable.unicodeScalars.allSatisfy(validName.contains) else { return false }
        let name = URL(fileURLWithPath: executable).lastPathComponent
        guard allowlist.contains(executable) || allowlist.contains(name) else { return false }

        if name == "find" {
            let mutatingActions = ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf", "-fls"]
            let arguments = trimmed.split(whereSeparator: \.isWhitespace).dropFirst().map(String.init)
            guard !arguments.contains(where: { mutatingActions.contains($0.lowercased()) }) else { return false }
        }
        return true
    }

    private static func evaluate(
        _ effect: PermissionEffect, context: ToolPermissionContext
    ) -> EffectEvaluation {
        if effect.capability == .userInput {
            let decision: PermissionDecision = context.surface == .interactive ? .allow : .deny
            return EffectEvaluation(effect: effect, decision: decision, source: .default)
        }

        let selected = selectedRule(for: effect, rules: context.conversationRules)
            .map { ($0, PermissionSource.conversationRule) }
            ?? selectedRule(for: effect, rules: context.modePolicy.rules)
                .map { ($0, PermissionSource.modeRule) }
        var decision = selected?.0.decision ?? effect.capability.defaultDecision(for: context.mode)
        var source = selected?.1 ?? .default

        if decision == .allow, let path = effect.path,
           let reason = ProtectedLocations.reason(for: path, workspace: context.workspace)
        {
            decision = .ask
            source = .protectedLocation(reason)
        }
        return EffectEvaluation(effect: effect, decision: decision, source: source)
    }

    private static func selectedRule(
        for effect: PermissionEffect, rules: [PermissionRule]
    ) -> PermissionRule? {
        rules.filter { $0.capability == effect.capability }
            .compactMap { rule -> (PermissionRule, Int)? in
                switch rule.scope {
                case .any:
                    return (rule, 0)
                case let .pathPrefix(prefix):
                    guard let path = effect.path,
                          PathScope.pathPrefixMatches(path, prefix: prefix)
                    else { return nil }
                    return (rule, PathScope.canonicalPath(prefix).count)
                }
            }
            .sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                return $0.0.decision.precedence > $1.0.decision.precedence
            }
            .first?.0
    }

    private static func mayAllow(_ capability: Capability, context: ToolPermissionContext) -> Bool {
        if capability == .userInput { return false }
        if capability == .shellAllowlisted, context.shellAllowlist.isEmpty { return false }

        let pathRules = (context.conversationRules + context.modePolicy.rules).filter {
            $0.capability == capability
        }.compactMap { rule -> String? in
            guard case let .pathPrefix(path) = rule.scope else { return nil }
            return PathScope.canonicalPath(path)
        }
        let candidatePaths: [String?]
        switch capability {
        case .workspaceRead, .workspaceWrite:
            let workspace = PathScope.canonicalURL(context.workspace)
            candidatePaths = ([workspace.appendingPathComponent("__permission_probe__").path]
                + pathRules.filter { PathScope.path($0, isWithin: workspace.path) })
                .map(Optional.some)
        case .externalRead, .externalWrite:
            let homeDocuments = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/__permission_probe__").path
            candidatePaths = ([homeDocuments, "/var/tmp/__permission_probe__"]
                + pathRules.filter { !PathScope.path($0, isWithin: context.workspace.path) })
                .filter {
                    ProtectedLocations.reason(for: $0, workspace: context.workspace) == nil
                }
                .map(Optional.some)
        default:
            candidatePaths = [nil]
        }

        return candidatePaths.contains { path in
            evaluate(PermissionEffect(capability, path: path), context: context).decision == .allow
        }
    }

    private static func unattended(
        _ decision: PermissionDecision, surface: PermissionSurface
    ) -> PermissionDecision {
        surface == .unattended && decision == .ask ? .deny : decision
    }

    private static func string(_ key: String, in arguments: [String: JSONValue]) -> String? {
        guard case let .string(value) = arguments[key] else { return nil }
        return value
    }
}