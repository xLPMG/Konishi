import SwiftUI
import AppKit

/// Browse and delete files the agent created for the current conversation, under ~/Konishi/files/<id>/.
struct FilesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [FileStore.Entry] = []
    @State private var selection: FileStore.Entry?

    private var conversationID: UUID? { model.selectedConversationID }

    var body: some View {
        NavigationSplitView {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView("No files", systemImage: "folder",
                                           description: Text("Files the assistant creates with python_exec in this conversation appear here."))
                } else {
                    List(entries, selection: $selection) { entry in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.name).lineLimit(1)
                                Text("\(byteString(entry.size)) · \(entry.modified.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: icon(for: entry))
                        }
                        .tag(entry)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
            .safeAreaInset(edge: .bottom) { bottomBar }
        } detail: {
            if let selection {
                detail(for: selection)
            } else {
                ContentUnavailableView("Select a file", systemImage: "doc")
            }
        }
        .navigationTitle("Files")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .onAppear(perform: reload)
        .onChange(of: conversationID) { _, _ in selection = nil; reload() }
    }

    private func detail(for entry: FileStore.Entry) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(entry.name).font(.headline).lineLimit(1)
                Spacer()
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                Button("Open") { NSWorkspace.shared.open(entry.url) }
                Button(role: .destructive) {
                    model.fileStore.delete(entry.url)
                    selection = nil
                    reload()
                } label: { Image(systemName: "trash") }
            }
            .padding(10)
            Divider()
            preview(for: entry)
        }
    }

    @ViewBuilder
    private func preview(for entry: FileStore.Entry) -> some View {
        if entry.isImage, let img = NSImage(contentsOf: entry.url) {
            ScrollView { Image(nsImage: img).resizable().scaledToFit().padding() }
        } else if let text = smallText(entry) {
            ScrollView {
                Text(text).font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(8)
            }
        } else {
            ContentUnavailableView("No preview", systemImage: "doc",
                                   description: Text("\(byteString(entry.size)) · use Open or Reveal to inspect."))
        }
    }

    private var bottomBar: some View {
        HStack {
            Button {
                if let id = conversationID { NSWorkspace.shared.open(Paths.conversationFiles(id)) }
            } label: {
                Label("Open Folder", systemImage: "folder")
            }
            .disabled(conversationID == nil)
            Spacer()
            Button(action: reload) { Image(systemName: "arrow.clockwise") }
        }
        .padding(6)
    }

    private func reload() {
        guard let id = conversationID else { entries = []; return }
        entries = model.fileStore.entries(conversation: id)
    }

    /// Text content for small, likely-text files (skip large or binary).
    private func smallText(_ entry: FileStore.Entry) -> String? {
        guard !entry.isDirectory, entry.size <= 200_000 else { return nil }
        return try? String(contentsOf: entry.url, encoding: .utf8)
    }

    private func icon(for entry: FileStore.Entry) -> String {
        if entry.isDirectory { return "folder" }
        if entry.isImage { return "photo" }
        switch entry.url.pathExtension.lowercased() {
        case "csv", "tsv": return "tablecells"
        case "json": return "curlybraces"
        case "py": return "chevron.left.forwardslash.chevron.right"
        case "txt", "md", "log": return "doc.text"
        default: return "doc"
        }
    }

    private func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
