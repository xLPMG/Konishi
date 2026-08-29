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
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search chats")
        .safeAreaInset(edge: .top) {
            Button { model.newConversation() } label: {
                Label(isLanguage ? "New Session" : "New Chat", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).padding(8)
        }
    }

    @ViewBuilder
    private func row(_ convo: Conversation) -> some View {
        let persona = model.persona(for: convo)
        HStack(spacing: 8) {
            Image(systemName: persona.iconSymbol)
                .foregroundStyle(persona.accentColorHex.map { Color(hex: $0) } ?? .accentColor)
            if renaming == convo.id {
                TextField("Title", text: $renameText, onCommit: commitRename)
                    .textFieldStyle(.roundedBorder)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(convo.title).lineLimit(1)
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
