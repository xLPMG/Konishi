import Foundation

enum PermissionDecision: String, Codable, Sendable {
    case allow
    case ask
    case deny

    var precedence: Int {
        switch self {
        case .deny: 3
        case .allow: 2
        case .ask: 1
        }
    }
}

enum PermissionScope: Equatable, Sendable {
    case any
    case pathPrefix(String)
}

extension PermissionScope: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case path
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "any": self = .any
        case "pathPrefix":
            self = .pathPrefix(try container.decode(String.self, forKey: .path))
        case let value:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "Unknown permission scope: \(value)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .any:
            try container.encode("any", forKey: .kind)
        case let .pathPrefix(path):
            try container.encode("pathPrefix", forKey: .kind)
            try container.encode(path, forKey: .path)
        }
    }
}

struct PermissionRule: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var capability: Capability
    var scope: PermissionScope
    var decision: PermissionDecision
    var createdAt: Date

    init(
        id: UUID = UUID(), capability: Capability, scope: PermissionScope = .any,
        decision: PermissionDecision, createdAt: Date = .now
    ) {
        self.id = id
        self.capability = capability
        self.scope = scope
        self.decision = decision
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, capability, scope, decision, createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        capability = try container.decode(Capability.self, forKey: .capability)
        scope = try container.decodeIfPresent(PermissionScope.self, forKey: .scope) ?? .any
        decision = try container.decodeIfPresent(PermissionDecision.self, forKey: .decision) ?? .ask
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
    }
}

struct PermissionPolicy: Codable, Equatable, Sendable {
    var rules: [PermissionRule]

    init(rules: [PermissionRule] = []) {
        self.rules = rules
    }

    private enum CodingKeys: String, CodingKey {
        case rules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rules = try container.decodeIfPresent([PermissionRule].self, forKey: .rules) ?? []
    }
}

enum PermissionSurface: String, Codable, Sendable {
    case interactive
    case unattended
}

enum PermissionRuleScopeChoice: Sendable {
    case containingFolder
    case anywhere
}