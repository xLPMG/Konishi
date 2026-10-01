import Foundation

/// A selectable identity: its own system prompt, memory folder, and optional model.
struct Persona: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var systemPrompt: String
    var memoryScope: String     // folder name under ~/Konishi/memory/
    var model: String?          // optional per-persona model override
    var iconSymbol: String
    var accentColorHex: String?
    /// The assistant's own name (distinct from this persona/mode label). Optional for back-compat.
    var assistantName: String?
    /// When on, this persona can retrieve from and read/write the research vault. Off keeps vault
    /// content out of this persona's chats entirely.
    var vaultAccessEnabled: Bool = false

    init(
        id: UUID = UUID(),
        name: String,
        systemPrompt: String,
        memoryScope: String,
        model: String? = nil,
        iconSymbol: String = "person.circle",
        accentColorHex: String? = nil,
        assistantName: String? = nil,
        vaultAccessEnabled: Bool = false
    ) {
        self.id = id
        self.name = name
        self.systemPrompt = systemPrompt
        self.memoryScope = memoryScope
        self.model = model
        self.iconSymbol = iconSymbol
        self.accentColorHex = accentColorHex
        self.assistantName = assistantName
        self.vaultAccessEnabled = vaultAccessEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, systemPrompt, memoryScope, model, iconSymbol, accentColorHex
        case assistantName, vaultAccessEnabled
    }

    // Tolerant decode so personas.json saved before newer fields existed still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        systemPrompt = try c.decode(String.self, forKey: .systemPrompt)
        memoryScope = try c.decode(String.self, forKey: .memoryScope)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        iconSymbol = try c.decodeIfPresent(String.self, forKey: .iconSymbol) ?? "person.circle"
        accentColorHex = try c.decodeIfPresent(String.self, forKey: .accentColorHex)
        assistantName = try c.decodeIfPresent(String.self, forKey: .assistantName)
        vaultAccessEnabled = try c.decodeIfPresent(Bool.self, forKey: .vaultAccessEnabled) ?? false
    }

    static var defaults: [Persona] {
        [
            Persona(
                name: "Assistant",
                systemPrompt: "You are a concise and helpful local assistant. Use Markdown when it aids clarity.",
                memoryScope: "assistant",
                iconSymbol: "sparkles",
                accentColorHex: "#6C8CFF"
            ),
            Persona(
                name: "Coder",
                systemPrompt: "You are in engineering mode. Prefer correct, idiomatic code with short explanations. When providing code, use fenced code blocks with a language tag.",
                memoryScope: "coder",
                iconSymbol: "chevron.left.forwardslash.chevron.right",
                accentColorHex: "#37C871"
            ),
            Persona(
                name: "Muse",
                systemPrompt: "You are in creative mode: imaginative, vivid, and playful, while staying coherent.",
                memoryScope: "muse",
                iconSymbol: "paintbrush.pointed",
                accentColorHex: "#FF7AB6"
            ),
            Persona(
                name: "Researcher",
                systemPrompt: "You are a precise research assistant. Distinguish sourced facts from uncertainty.",
                memoryScope: "researcher",
                iconSymbol: "books.vertical",
                accentColorHex: "#F5A623",
                vaultAccessEnabled: true
            )
        ]
    }
}
