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
    /// Explicit assistant name; when absent, the persona's name is used.
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
