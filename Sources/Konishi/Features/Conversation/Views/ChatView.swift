import SwiftUI
import UniformTypeIdentifiers
import PDFKit

struct ChatView: View {
    @Environment(AppModel.self) private var model
    @State private var showImporter = false
    @State private var showDocImporter = false
    @State private var pinnedToBottom = true

    var body: some View {
        VStack(spacing: 0) {
            messageList
            if let error = model.errorMessage { errorBanner(error) }
            if let voiceError = model.voice.lastError { voiceBanner(voiceError) }
            if model.isStreaming, let activity = model.activity { activityLine(activity) }
            if let batch = model.pendingApproval { ToolApprovalBar(batch: batch) }
            StatsBar()
            attachmentStrip
            inputBar
        }
        .animation(.easeInOut(duration: 0.15), value: model.activity)
        .navigationTitle(model.selectedConversation?.title ?? "Konishi")
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                if model.voice.isSpeaking {
                    Button { model.voice.stopSpeaking() } label: {
                        Label("Stop Voice", systemImage: "speaker.slash")
                    }
                }
                if model.isStreaming {
                    Button(role: .destructive) { model.stop() } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                }
                Button { model.clearCurrent() } label: { Label("Clear", systemImage: "eraser") }
                    .disabled(model.selectedConversation?.messages.isEmpty ?? true)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { urls.forEach(addImage) }
        }
        .fileImporter(isPresented: $showDocImporter,
                      allowedContentTypes: [.pdf, .plainText, .text, .sourceCode, .json, .xml, .commaSeparatedText, .rtf],
                      allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { urls.forEach(addDocument) }
        }
    }

    /// Documents indexed for retrieval (RAG) in the current conversation.
    private var indexedDocuments: [StoredDocument] {
        model.selectedConversationID.map { model.documentStore.documents(for: $0) } ?? []
    }

    /// Renders user messages and collapsed multi-step assistant turns (reasoning, tool calls,
    /// and final replies) as unified visual bubbles.
    private var chatItems: [ChatItem] {
        let raw = model.selectedConversation?.messages ?? []
        var items: [ChatItem] = []
        var currentAssistantSteps: [AssistantStep] = []
        var currentAssistantToolResults: [String: String] = [:]
        var currentAssistantAllIDs: [UUID] = []
        var currentAssistantSources: [Source] = []
        var currentAssistantInterrupted = false
        var currentAssistantImages: [String] = []
        var currentAssistantAttachments: [Attachment] = []

        func flushAssistant() {
            guard !currentAssistantSteps.isEmpty else { return }
            let turn = AssistantTurn(
                id: currentAssistantSteps[0].id,
                steps: currentAssistantSteps,
                toolResults: currentAssistantToolResults,
                sources: currentAssistantSources,
                interrupted: currentAssistantInterrupted,
                images: currentAssistantImages,
                attachments: currentAssistantAttachments,
                allMessageIDs: currentAssistantAllIDs
            )
            if turn.hasVisibleContent {
                items.append(.assistant(turn))
            }
            currentAssistantSteps = []
            currentAssistantToolResults = [:]
            currentAssistantAllIDs = []
            currentAssistantSources = []
            currentAssistantInterrupted = false
            currentAssistantImages = []
            currentAssistantAttachments = []
        }

        for msg in raw {
            switch msg.role {
            case .user:
                if msg.content == "Plot(s) generated:", !msg.images.isEmpty, !currentAssistantSteps.isEmpty {
                    currentAssistantAllIDs.append(msg.id)
                    currentAssistantImages.append(contentsOf: msg.images)
                    break
                }
                flushAssistant()
                items.append(.user(msg))
            case .assistant:
                currentAssistantAllIDs.append(msg.id)
                currentAssistantSteps.append(AssistantStep(
                    id: msg.id,
                    reasoning: msg.reasoning,
                    content: msg.content,
                    toolCalls: msg.toolCalls
                ))
                if !msg.sources.isEmpty {
                    for src in msg.sources {
                        if !currentAssistantSources.contains(where: { $0.url == src.url }) {
                            currentAssistantSources.append(src)
                        }
                    }
                }
                if msg.interrupted { currentAssistantInterrupted = true }
                if !msg.images.isEmpty { currentAssistantImages.append(contentsOf: msg.images) }
                if !msg.attachments.isEmpty { currentAssistantAttachments.append(contentsOf: msg.attachments) }
            case .tool:
                currentAssistantAllIDs.append(msg.id)
                if let callId = msg.toolCallId {
                    currentAssistantToolResults[callId] = msg.content
                }
            case .system:
                break
            }
        }
        flushAssistant()
        return items
    }

    private var messageList: some View {
        let items = self.chatItems
        let lastMessage = model.selectedConversation?.messages.last
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if items.isEmpty { emptyState }
                    ForEach(items) { item in
                        switch item {
                        case .user(let message):
                            UserMessageRow(message: message).id(item.id)
                        case .assistant(let turn):
                            AssistantTurnRow(turn: turn).id(item.id)
                        }
                    }
                }
                .padding(16)
            }
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 40
            } action: { _, atBottom in
                pinnedToBottom = atBottom
            }
            .onChange(of: lastMessage?.content) {
                guard pinnedToBottom, let last = items.last else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: lastMessage?.reasoning) {
                guard pinnedToBottom, let last = items.last else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: model.selectedConversation?.messages.count) {
                guard pinnedToBottom, let last = items.last else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: model.selectedConversationID) {
                pinnedToBottom = true
                if let last = items.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: model.currentPersona.iconSymbol)
                .font(.largeTitle).foregroundStyle(model.currentAccent)
            Text("Chatting with \(model.currentAssistantName)").font(.title3.weight(.semibold))
            Text(model.settings.baseURL).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    private func errorBanner(_ text: String) -> some View {
        banner(text, symbol: "exclamationmark.triangle.fill", tint: .orange) { model.errorMessage = nil }
    }

    private func voiceBanner(_ text: String) -> some View {
        banner(text, symbol: "mic.slash.fill", tint: .red) { model.voice.lastError = nil }
    }

    private func activityLine(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.callout).foregroundStyle(.secondary).contentTransition(.opacity)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
    }

    private func banner(_ text: String, symbol: String, tint: Color, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.callout).textSelection(.enabled)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12).padding(.top, 8)
    }

    @ViewBuilder
    private var attachmentStrip: some View {
        if !model.draftImages.isEmpty || !model.draftAttachments.isEmpty || !indexedDocuments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(model.draftImages.enumerated()), id: \.offset) { idx, dataURL in
                        ZStack(alignment: .topTrailing) {
                            if let img = Self.nsImage(from: dataURL) {
                                Image(nsImage: img).resizable().scaledToFill()
                                    .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            Button { model.draftImages.remove(at: idx) } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain).foregroundStyle(.white, .black.opacity(0.6))
                        }
                    }
                    ForEach(model.draftAttachments) { doc in
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text").foregroundStyle(.secondary)
                            Text(doc.name).font(.caption).lineLimit(1)
                            Button { model.draftAttachments.removeAll { $0.id == doc.id } } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                        .help("\(doc.text.count) characters")
                    }
                    ForEach(indexedDocuments) { doc in
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.blue)
                            Text(doc.name).font(.caption).lineLimit(1)
                            Button {
                                if let convoID = model.selectedConversationID {
                                    model.documentStore.delete(id: doc.id, conversationID: convoID)
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(.blue.opacity(0.12), in: Capsule())
                        .help("Indexed for retrieval · \(doc.chunks.count) passages, \(doc.charCount) characters")
                    }
                }
                .padding(.horizontal, 12).padding(.top, 8)
            }
        }
    }

    private var inputBar: some View {
        @Bindable var model = model
        return HStack(alignment: .center, spacing: 10) {
            Menu {
                Button { showImporter = true } label: { Label("Image…", systemImage: "photo") }
                Button { showDocImporter = true } label: { Label("PDF or Text File…", systemImage: "doc") }
            } label: {
                Image(systemName: "plus.circle").font(.title3)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Attach image or file")

            ContextGauge(used: model.selectedConversation?.lastStats?.promptTokens ?? 0, window: model.contextWindow)

            Button { model.settings.reasoningEnabled.toggle() } label: {
                Image(systemName: "brain")
                    .font(.title3)
                    .foregroundStyle(model.settings.reasoningEnabled ? AnyShapeStyle(model.currentAccent) : AnyShapeStyle(.secondary))
                    .opacity(model.settings.reasoningEnabled ? 1 : 0.55)
            }
            .buttonStyle(.plain)
            .help(model.settings.reasoningEnabled ? "Reasoning on — model thinks before answering (slower). Click to turn off." : "Reasoning off — faster replies. Click to turn on.")

            Button { model.toggleDictation() } label: {
                Image(systemName: model.voice.isListening ? "mic.fill" : "mic")
                    .font(.title3)
                    .foregroundStyle(model.voice.isListening ? .red : .primary)
                    .symbolEffect(.pulse, isActive: model.voice.isListening)
            }
            .buttonStyle(.plain).help("Dictate")

            TextField("Message \(model.currentAssistantName)…", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: model.settings.fontSize))
                .lineLimit(1...8)
                .padding(.vertical, 4)
                .onKeyPress(keys: [.return]) { keyPress in
                    if keyPress.modifiers.contains(.shift) {
                        model.draft.append("\n")
                        return .handled
                    }
                    model.send()
                    return .handled
                }

            Button { model.send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                .buttonStyle(.plain)
                .disabled(!model.canSend)
                .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .padding(.top, 4)
    }

    private func addImage(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url) else { return }
        let ext = url.pathExtension.lowercased()
        let mime = ext == "png" ? "image/png" : (ext == "gif" ? "image/gif" : "image/jpeg")
        model.draftImages.append("data:\(mime);base64,\(data.base64EncodedString())")
    }

    private func addDocument(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        var text: String?
        if url.pathExtension.lowercased() == "pdf" {
            text = PDFDocument(url: url)?.string
        } else if let data = try? Data(contentsOf: url) {
            text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        }
        guard var extracted = text?.trimmingCharacters(in: .whitespacesAndNewlines), !extracted.isEmpty else { return }
        let maxChars = 100_000   // keep large files from blowing the context budget
        if extracted.count > maxChars {
            extracted = String(extracted.prefix(maxChars)) + "\n\n[truncated \(extracted.count - maxChars) more characters]"
        }
        // Inline small attachments; index large ones for retrieval.
        if model.settings.ragThresholdChars > 0, extracted.count > model.settings.ragThresholdChars,
            let convoID = model.selectedConversationID
        {
            model.documentStore.add(name: url.lastPathComponent, text: extracted, conversationID: convoID)
        } else {
            model.draftAttachments.append(Attachment(name: url.lastPathComponent, text: extracted))
        }
    }

    static func nsImage(from dataURL: String) -> NSImage? {
        guard let comma = dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
        else { return nil }
        return NSImage(data: data)
    }
}

private struct ToolApprovalBar: View {
    @Environment(AppModel.self) private var model
    let batch: AppModel.PendingToolBatch

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("The model wants to run \(batch.calls.count) tool call(s)", systemImage: "wrench.and.screwdriver.fill")
                .font(.callout.weight(.semibold))
            ForEach(batch.calls) { call in
                if call.function.name == "run_shell",
                   let args: ToolArguments.Shell = decodeArguments(call) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Shell command", systemImage: "terminal")
                            .font(.caption.weight(.semibold))
                        ScrollView([.horizontal, .vertical]) {
                            Text(args.command)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: true)
                        }
                            .defaultScrollAnchor(.topLeading)
                        .frame(height: 18)
                        .padding(6)
                        .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                        Text("Working directory: \(args.workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("Timeout: \(max(1, min(args.timeoutSeconds ?? 120, 600))) seconds")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("• \(call.function.name ?? "tool")(\(call.function.arguments))")
                        .font(.system(size: 12, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            HStack {
                Button("Approve") { model.approveTools() }.buttonStyle(.borderedProminent)
                Button("Deny") { model.denyTools() }
                Spacer()
            }
        }
        .padding(10)
        .background(model.currentAccent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12).padding(.top, 8)
    }

    private func decodeArguments<T: Decodable>(_ call: ToolCall) -> T? {
        guard let data = call.function.arguments.data(using: .utf8) else { return nil }
        return try? Wire.decoder.decode(T.self, from: data)
    }
}

struct AssistantStep: Identifiable, Sendable {
    let id: UUID
    let reasoning: String?
    let content: String
    let toolCalls: [ToolCall]?

    var hasVisibleContent: Bool {
        !(reasoning?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            || !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(toolCalls?.isEmpty ?? true)
    }
}

struct AssistantTurn: Identifiable, Sendable {
    let id: UUID
    let steps: [AssistantStep]
    let toolResults: [String: String]
    let sources: [Source]
    let interrupted: Bool
    let images: [String]
    let attachments: [Attachment]
    let allMessageIDs: [UUID]

    var lastMessageID: UUID { steps.last?.id ?? id }

    var hasVisibleContent: Bool {
        steps.contains { $0.hasVisibleContent } || !images.isEmpty || !attachments.isEmpty
    }
}

enum ChatItem: Identifiable {
    case user(ChatMessage)
    case assistant(AssistantTurn)

    var id: UUID {
        switch self {
        case .user(let msg): return msg.id
        case .assistant(let turn): return turn.id
        }
    }
}

private struct UserMessageRow: View {
    @Environment(AppModel.self) private var model
    let message: ChatMessage
    @State private var hovering = false
    @State private var zoom: IdentifiableImage?

    var body: some View {
        HStack {
            Spacer(minLength: 60)
            VStack(alignment: .leading, spacing: 6) {
                Text("You")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                if !message.images.isEmpty { imageGrid }
                if !message.attachments.isEmpty { attachmentChips }
                Text(message.content)
                    .font(.system(size: model.settings.fontSize))
                    .textSelection(.enabled)
                    .foregroundStyle(.white)
                if hovering { actions }
            }
            .padding(10)
            .background(model.currentAccent, in: RoundedRectangle(cornerRadius: 12))
        }
        .onHover { hovering = $0 }
        .sheet(item: $zoom) { ZoomImageView(image: $0.image) }
        .contextMenu {
            Button("Copy Message", systemImage: "doc.on.doc") { copyMessage() }
        }
    }

    private var imageGrid: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(Array(message.images.enumerated()), id: \.offset) { _, dataURL in
                if let img = ChatView.nsImage(from: dataURL) {
                    Button { zoom = IdentifiableImage(image: img) } label: {
                        Image(nsImage: img).resizable().scaledToFit()
                            .frame(maxWidth: 360, maxHeight: 280)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help("Click to enlarge")
                }
            }
        }
    }

    private var attachmentChips: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(message.attachments) { doc in
                Label(doc.name, systemImage: "doc.text")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .help("\(doc.text.count) characters attached")
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button { copyMessage() } label: { Image(systemName: "doc.on.doc") }
            Button { model.branch(fromMessage: message.id) } label: { Image(systemName: "arrow.triangle.branch") }
            Button { model.deleteMessage(message.id) } label: { Image(systemName: "trash") }
        }
        .buttonStyle(.plain).font(.caption)
        .foregroundStyle(.white.opacity(0.85))
    }

    private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
    }
}

private struct AssistantTurnRow: View {
    @Environment(AppModel.self) private var model
    let turn: AssistantTurn
    @State private var hovering = false
    @State private var zoom: IdentifiableImage?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.currentAssistantName)
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                if !turn.images.isEmpty { imageGrid }
                if !turn.attachments.isEmpty { attachmentChips }

                let visibleSteps = turn.steps.filter(\.hasVisibleContent)
                let reasoningCount = turn.steps.filter { !($0.reasoning?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }.count

                ForEach(Array(visibleSteps.enumerated()), id: \.element.id) { idx, step in
                    VStack(alignment: .leading, spacing: 6) {
                        if let reasoning = step.reasoning,
                           !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let title = reasoningCount > 1 ? "Reasoning (Step \(idx + 1))" : "Reasoning"
                            ReasoningDisclosureView(reasoning: reasoning, title: title)
                        }
                        if !step.content.isEmpty {
                            MarkdownView(text: step.content, baseSize: model.settings.fontSize)
                                .textSelection(.enabled)
                        }
                        if let toolCalls = step.toolCalls, !toolCalls.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(toolCalls) { call in
                                    ToolCallView(call: call, result: turn.toolResults[call.id])
                                }
                            }
                        }
                    }
                }

                if turn.interrupted {
                    Label("Interrupted", systemImage: "waveform.badge.minus")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if !turn.sources.isEmpty { sourcesView }
                if hovering { actions }
            }
            .padding(10)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
            Spacer(minLength: 60)
        }
        .onHover { hovering = $0 }
        .sheet(item: $zoom) { ZoomImageView(image: $0.image) }
        .contextMenu {
            Button("Copy Message", systemImage: "doc.on.doc") { copyTurn() }
        }
    }

    private var imageGrid: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(Array(turn.images.enumerated()), id: \.offset) { _, dataURL in
                if let img = ChatView.nsImage(from: dataURL) {
                    Button { zoom = IdentifiableImage(image: img) } label: {
                        Image(nsImage: img).resizable().scaledToFit()
                            .frame(maxWidth: 360, maxHeight: 280)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help("Click to enlarge")
                }
            }
        }
    }

    private var attachmentChips: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(turn.attachments) { doc in
                Label(doc.name, systemImage: "doc.text")
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .help("\(doc.text.count) characters attached")
            }
        }
    }

    private var sourcesView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Sources", systemImage: "link")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(turn.sources.enumerated()), id: \.element.id) { idx, src in
                        if let url = URL(string: src.url) {
                            Link(destination: url) {
                                HStack(spacing: 4) {
                                    Text("\(idx + 1)").font(.caption2.weight(.bold))
                                    Image(systemName: "arrow.up.forward.app").font(.caption2)
                                    Text(Self.sourceLabel(src)).font(.caption2).lineLimit(1)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.blue.opacity(0.14), in: Capsule())
                            }
                            .buttonStyle(.plain).foregroundStyle(.blue)
                            .help(src.title.isEmpty ? src.url : "\(src.title)\n\(src.url)")
                        }
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    private static func sourceLabel(_ src: Source) -> String {
        if let host = URL(string: src.url)?.host {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return src.title.isEmpty ? src.url : src.title
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button { copyTurn() } label: { Image(systemName: "doc.on.doc") }
            Button {
                let text = turn.steps.last(where: { !$0.content.isEmpty })?.content ?? ""
                model.speak(text)
            } label: { Image(systemName: "speaker.wave.2") }
            Group {
                Button { model.regenerate(messageID: turn.id) } label: { Image(systemName: "arrow.clockwise") }
                Button { model.branch(fromMessage: turn.lastMessageID) } label: { Image(systemName: "arrow.triangle.branch") }
                Button { model.deleteTurn(messageIDs: turn.allMessageIDs) } label: { Image(systemName: "trash") }
            }
            .disabled(model.isStreaming || model.pendingApproval != nil)
        }
        .buttonStyle(.plain).font(.caption)
        .foregroundStyle(.secondary)
    }

    private func copyTurn() {
        let text = turn.steps
            .map(\.content)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct ReasoningDisclosureView: View {
    @Environment(AppModel.self) private var model
    let reasoning: String
    var title: String = "Reasoning"
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(reasoning)
                .font(.system(size: max(11, model.settings.fontSize - 2)))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Label(title, systemImage: "brain")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ToolCallView: View {
    let call: ToolCall
    let result: String?
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: toolIcon(call.function.name ?? ""))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(toolSummary(call))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help(call.function.arguments)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    if !call.function.arguments.isEmpty && call.function.arguments != "{}" {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Arguments")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(call.function.arguments)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(6)
                        .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    }
                    if let result, !result.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Result")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ScrollView {
                                Text(result.prefix(4000))
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 120)
                        }
                        .padding(6)
                        .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                .padding(6)
                .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func toolIcon(_ name: String) -> String {
        switch name {
        case "web_search", "web_research": return "magnifyingglass"
        case "web_fetch": return "globe"
        case "calculate": return "function"
        case "python_exec": return "chevron.left.forwardslash.chevron.right"
        case "run_shell": return "terminal"
        case "file_read": return "doc.text"
        case "vault_search", "vault_read", "vault_list", "vault_write", "vault_append": return "lock.doc"
        case "memory_list", "memory_read", "memory_write", "memory_append": return "brain.head.profile"
        case "add_vocab", "add_grammar", "search_deck", "get_due_items", "record_review": return "character.book.closed"
        case "ask_multiple_choice": return "questionmark.bubble"
        default: return "wrench.and.screwdriver"
        }
    }

    private func toolSummary(_ call: ToolCall) -> String {
        let name = call.function.name ?? "tool"
        if let data = call.function.arguments.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let q = json["query"] as? String, !q.isEmpty {
                return "\(name)(\"\(q)\")"
            }
            if let expr = json["expression"] as? String, !expr.isEmpty {
                return "\(name)(\(expr))"
            }
            if let cmd = json["command"] as? String, !cmd.isEmpty {
                return "\(name)(\(cmd))"
            }
            if let url = json["url"] as? String, !url.isEmpty {
                return "\(name)(\(url))"
            }
            if let note = json["note"] as? String, !note.isEmpty {
                return "\(name)(\(note))"
            }
            if let path = json["path"] as? String, !path.isEmpty {
                return "\(name)(\(path))"
            }
        }
        return name
    }
}

private struct IdentifiableImage: Identifiable {
    let id = UUID()
    let image: NSImage
}

/// Full-size, zoomable/pannable preview for an attached image.
private struct ZoomImageView: View {
    @Environment(\.dismiss) private var dismiss
    let image: NSImage
    @State private var scale: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(8)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable().scaledToFit()
                    .scaleEffect(scale)
                    .padding()
                    .gesture(MagnificationGesture().onChanged { scale = max(0.5, min($0, 6)) })
            }
        }
        .frame(minWidth: 560, minHeight: 440)
    }
}

