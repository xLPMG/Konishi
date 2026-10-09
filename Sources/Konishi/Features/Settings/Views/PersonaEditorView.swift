import SwiftUI
import AppKit

struct PersonaEditorView: View {
    @Environment(AppModel.self) private var model
    @State private var draft: Persona

    init(persona: Persona) {
        _draft = State(initialValue: persona)
    }

    private let symbols = [
        "sparkles", "chevron.left.forwardslash.chevron.right", "paintbrush.pointed",
        "person.circle", "brain", "book", "terminal", "wand.and.stars", "graduationcap",
        "lightbulb", "flame", "leaf"
    ]

    var body: some View {
        Form {
            Section {
                TextField("Mode name", text: $draft.name)
                TextField("Assistant name", text: Binding(
                    get: { draft.assistantName ?? "" },
                    set: { draft.assistantName = $0.isEmpty ? nil : $0 }
                ), prompt: Text("What the AI calls itself (optional)"))
                Picker("Icon", selection: $draft.iconSymbol) {
                    ForEach(symbols, id: \.self) { Image(systemName: $0).tag($0) }
                }
                ColorPicker("Accent", selection: Binding(
                    get: { draft.accentColorHex.map { Color(hex: $0) } ?? .accentColor },
                    set: { draft.accentColorHex = $0.hexString }
                ))
            }
            Section("Model preference") {
                TextField("Model (blank = use chat selection)", text: Binding(
                    get: { draft.model ?? "" },
                    set: { draft.model = $0.isEmpty ? nil : $0 }
                ))
            }
            Section("Memory scope") {
                TextField("Folder name", text: $draft.memoryScope)
                Text("Files live in ~/Konishi/memory/\(draft.memoryScope)/")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Research vault") {
                Toggle("Research vault access", isOn: $draft.vaultAccessEnabled)
                Text("When on, this persona searches, reads, and writes notes in your Obsidian vault (Settings › Vault), and relevant notes are injected into its replies. Keep it off for everyday personas so vault content stays out of those chats.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("System Prompt") {
                TextEditor(text: $draft.systemPrompt)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(minHeight: 120)
            }
        }
        .formStyle(.columns)
        .themedFormBackground(model.currentPalette.canvas)
        .onChange(of: draft) { model.personaStore.updatePersona(draft) }
    }
}
