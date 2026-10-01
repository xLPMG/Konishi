import SwiftUI
import AppKit

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: UUID?
    @State private var renameText = ""

    var body: some View {
        @Bindable var model = model
        let isLanguage = model.mode == .language
        List(selection: Binding(
            get: { model.selectedConversationID },
            set: { if let id = $0 { model.selectedConversationID = id } }
        )) {
            Section(isLanguage ? "Language Sessions" : "Conversations") {
                ForEach(model.filteredConversations) { convo in
                    row(convo).tag(convo.id)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .searchable(text: $model.searchText, placement: .sidebar, prompt: isLanguage ? "Search sessions" : "Search chats")
        .safeAreaInset(edge: .top) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: isLanguage ? "character.book.closed.fill" : "sparkles")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(model.currentAccent)
                        .frame(width: 36, height: 36)
                        .background(model.currentAccent.opacity(0.13), in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Konishi").font(.headline)
                        Text(isLanguage ? "LEARNING DESK" : "CHAT STUDIO")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Text("\(model.filteredConversations.count)")
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(KonishiPalette.surface, in: Capsule())
                }

                Button { model.newConversation() } label: {
                    Label(isLanguage ? "New Session" : "New Chat", systemImage: "square.and.pencil")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .background(KonishiPalette.surface)
        }
        .background(KonishiPalette.surface.ignoresSafeArea())
    }

    @ViewBuilder
    private func row(_ convo: Conversation) -> some View {
        let persona = model.personaStore.persona(for: convo)
        HStack(spacing: 8) {
            Image(systemName: persona.iconSymbol)
                .foregroundStyle(persona.accentColorHex.map { Color(hex: $0) } ?? .accentColor)
            if renaming == convo.id {
                TextField("Title", text: $renameText, onCommit: commitRename)
                    .textFieldStyle(.roundedBorder)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(convo.title)
                        .font(.body.weight(model.selectedConversationID == convo.id ? .semibold : .regular))
                        .lineLimit(1)
                    Text(persona.name).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .contextMenu {
            Button("Rename") { startRename(convo) }
            Button("Export Markdown…") { export(convo) }
            Divider()
            Button("Delete", role: .destructive) { model.deleteConversation(convo.id) }
        }
    }

    private func startRename(_ convo: Conversation) {
        renameText = convo.title
        renaming = convo.id
    }

    private func commitRename() {
        if let id = renaming { model.renameConversation(id, to: renameText) }
        renaming = nil
    }

    private func export(_ convo: Conversation) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = convo.title.replacingOccurrences(of: "/", with: "-") + ".md"
        panel.allowedContentTypes = [.init(filenameExtension: "md")].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? model.exportMarkdown(convo).write(to: url, atomically: true, encoding: .utf8)
    }
}
