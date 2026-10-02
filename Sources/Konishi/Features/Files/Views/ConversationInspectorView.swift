import SwiftUI
import AppKit

struct ConversationInspectorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    @State private var tasksExpanded = false
    @State private var confirmingClearTasks = false
    @State private var filesExpanded = true
    @State private var previewExpanded = true
    @State private var traceExpanded = false
    @State private var entries: [FileStore.Entry] = []
    @State private var selection: FileStore.Entry?

    private var conversationID: UUID? { model.selectedConversationID }
    private var visibleTrace: [TraceEntry] { model.currentTrace.filter { $0.kind != .token } }
    private var tasks: [ConversationTask] { model.selectedConversation?.tasks ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Conversation").font(.headline)
                Spacer()
                Text(model.selectedConversation?.title ?? "No conversation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 6) {
                        DisclosureGroup(isExpanded: $tasksExpanded) {
                            ConversationTaskBoard(showsHeader: false)
                        } label: {
                            HStack {
                                Label("Tasks & Notes", systemImage: "checklist")
                                Spacer()
                                Text("\(tasks.filter { $0.status == .done }.count)/\(tasks.count)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if !tasks.isEmpty {
                            Button(role: .destructive) {
                                confirmingClearTasks = true
                            } label: {
                                Image(systemName: "trash")
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(.borderless)
                            .help("Remove all tasks")
                        }
                    }

                    DisclosureGroup(isExpanded: $filesExpanded) {
                        filesSection
                    } label: {
                        HStack {
                            Label("Files", systemImage: "folder")
                            Spacer()
                            Text("\(entries.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }

                    DisclosureGroup(isExpanded: $previewExpanded) {
                        previewSection
                    } label: {
                        HStack {
                            Label("Preview", systemImage: "doc.text.magnifyingglass")
                            Spacer(minLength: 6)
                            Text(selection?.name ?? "No selection")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    DisclosureGroup(isExpanded: $traceExpanded) {
                        traceSection
                    } label: {
                        HStack {
                            Label("Trace", systemImage: "list.bullet.rectangle")
                            Spacer()
                            Text("\(visibleTrace.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(12)
            }
        }
        .background(model.currentPalette.sidebar)
        .confirmationDialog(
            "Remove all tasks?", isPresented: $confirmingClearTasks,
            titleVisibility: .visible
        ) {
            Button("Remove All Tasks", role: .destructive) {
                model.deleteAllConversationTasks()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every task and its notes from this conversation.")
        }
        .onAppear(perform: reload)
        .onChange(of: conversationID) { _, id in
            selection = nil
            reload()
            if let id { model.traceStore.ensureTraceLoaded(conversationID: id) }
        }
        .onChange(of: model.currentTrace.last?.id) { _, _ in
            if model.currentTrace.last?.kind == .result { reload() }
        }
    }

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if entries.isEmpty {
                Text(conversationID == nil ? "Select a conversation to see its files." : "No files in this conversation yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                ForEach(entries) { entry in
                    Button {
                        selection = entry
                        previewExpanded = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: icon(for: entry))
                                .foregroundStyle(selection == entry ? model.currentAccent : .secondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                    .font(.system(size: 12, weight: selection == entry ? .semibold : .regular))
                                    .lineLimit(1)
                                Text("\(byteString(entry.size)) · \(entry.modified.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 6)
                        .background(
                            selection == entry ? model.currentPalette.surfaceRaised : .clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(entry.url.path)
                }
            }

            HStack(spacing: 12) {
                Button {
                    if let id = conversationID { NSWorkspace.shared.open(Paths.conversationFiles(id)) }
                } label: {
                    Label("Open Folder", systemImage: "folder")
                }
                .disabled(conversationID == nil)
                Spacer()
                Button(action: reload) { Image(systemName: "arrow.clockwise") }
                    .help("Refresh files")
                    .disabled(conversationID == nil)
            }
            .font(.caption)
            .padding(.top, 2)
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private var previewSection: some View {
        if let selection {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([selection.url])
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .help("Reveal in Finder")

                    Button { NSWorkspace.shared.open(selection.url) } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .help("Open file")

                    Spacer()

                    Button(role: .destructive) {
                        model.fileStore.delete(selection.url)
                        self.selection = nil
                        reload()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Delete file")
                }
                .buttonStyle(.borderless)

                filePreview(selection)
            }
        } else {
            Text("Choose a file above to preview it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func filePreview(_ entry: FileStore.Entry) -> some View {
        if entry.isImage, let image = NSImage(contentsOf: entry.url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 220)
                .frame(maxWidth: .infinity)
        } else if let text = smallText(entry) {
            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(maxHeight: 220)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        } else {
            Text("\(byteString(entry.size)) · Open the file to inspect its contents.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var traceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if visibleTrace.isEmpty {
                Text("No trace events yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                ForEach(Array(visibleTrace.suffix(6).reversed())) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            Image(systemName: traceSymbol(entry.kind))
                                .foregroundStyle(traceColor(entry.kind))
                            Text(entry.kind.rawValue.capitalized)
                                .font(.caption2.weight(.semibold))
                            Spacer(minLength: 4)
                            Text(entry.date, format: .dateTime.hour().minute().second())
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.text)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(traceColor(entry.kind).opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
            }

            HStack {
                Button { openWindow(id: "trace") } label: {
                    Label("Open Full Trace", systemImage: "arrow.up.forward.app")
                }
                .disabled(conversationID == nil)
                Spacer()
            }
            .font(.caption)
            .padding(.top, 2)
        }
        .padding(.top, 6)
    }

    private func reload() {
        guard let id = conversationID else { entries = []; return }
        entries = model.fileStore.entries(conversation: id)
        model.traceStore.ensureTraceLoaded(conversationID: id)
    }

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

    private func traceSymbol(_ kind: TraceEntry.Kind) -> String {
        switch kind {
        case .request: "arrow.up.circle"
        case .token: "bolt"
        case .reasoning: "brain"
        case .usage: "number"
        case .tool: "wrench.and.screwdriver"
        case .result: "arrow.down.circle"
        case .finish: "flag.checkered"
        case .error: "exclamationmark.triangle"
        case .info: "info.circle"
        case .compress: "arrow.down.right.and.arrow.up.left"
        case .memory: "tray.full"
        }
    }

    private func traceColor(_ kind: TraceEntry.Kind) -> Color {
        switch kind {
        case .request: .blue
        case .token: .green
        case .reasoning: .purple
        case .usage: .teal
        case .tool: .orange
        case .result: .indigo
        case .finish: .gray
        case .error: .red
        case .info: .secondary
        case .compress: .brown
        case .memory: .pink
        }
    }
}