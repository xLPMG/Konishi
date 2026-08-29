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

    /// Text/code replies are shown as messages; tool calls and their results are collapsed
    /// into the single replacing `activityLine` and remain visible in the Trace.
    private var messages: [ChatMessage] {
        (model.selectedConversation?.messages ?? []).filter { m in
            switch m.role {
            case .tool: return false
            case .assistant: return !m.content.isEmpty
            default: return true
            }
        }
    }

    private var messageList: some View {
        let messages = self.messages
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if messages.isEmpty { emptyState }
                    ForEach(messages) { message in
                        MessageRow(message: message).id(message.id)
                    }
                }
                .padding(16)
            }
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 40
            } action: { _, atBottom in
                pinnedToBottom = atBottom
            }
            .onChange(of: messages.last?.content) {
                guard pinnedToBottom, let last = messages.last else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: model.selectedConversationID) {
                pinnedToBottom = true
                if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
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
        if !model.draftImages.isEmpty || !model.draftAttachments.isEmpty || !model.indexedDocuments.isEmpty {
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
                    ForEach(model.indexedDocuments) { doc in
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.blue)
                            Text(doc.name).font(.caption).lineLimit(1)
                            Button { model.removeIndexedDocument(doc.id) } label: {
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
                .onKeyPress(.return) {
                    // Enter sends; Shift+Enter falls through to insert a newline.
                    guard !NSEvent.modifierFlags.contains(.shift) else { return .ignored }
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
        model.addDocument(name: url.lastPathComponent, text: extracted)
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
                Text("• \(call.function.name ?? "tool")(\(call.function.arguments))")
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(2).textSelection(.enabled)
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
}

private struct MessageRow: View {
    @Environment(AppModel.self) private var model
    let message: ChatMessage
    @State private var hovering = false
    @State private var zoom: IdentifiableImage?

    private var isUser: Bool { message.role == .user }

    var body: some View {
        bubble
            .sheet(item: $zoom) { ZoomImageView(image: $0.image) }
    }

    private var bubble: some View {
        HStack {
            if isUser { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 6) {
                Text(isUser ? "You" : model.currentAssistantName)
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                if !message.images.isEmpty { imageGrid }
                if !message.attachments.isEmpty { attachmentChips }
                content
                if message.interrupted {
                    Label("Interrupted", systemImage: "waveform.badge.minus")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if !message.sources.isEmpty { sourcesView }
                if hovering { actions }
            }
            .padding(10)
            .background(bubbleBackground, in: RoundedRectangle(cornerRadius: 12))
            if !isUser { Spacer(minLength: 60) }
        }
        .onHover { hovering = $0 }
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
                    .foregroundStyle(isUser ? .white : .primary)
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
                    ForEach(Array(message.sources.enumerated()), id: \.element.id) { idx, src in
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

    /// Short, readable label for a source chip: the host without a leading "www.".
    private static func sourceLabel(_ src: Source) -> String {
        if let host = URL(string: src.url)?.host {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return src.title.isEmpty ? src.url : src.title
    }

    @ViewBuilder
    private var content: some View {
        if isUser {
            Text(message.content).font(.system(size: model.settings.fontSize))
                .textSelection(.enabled).foregroundStyle(.white)
        } else if !message.content.isEmpty {
            MarkdownView(text: message.content, baseSize: model.settings.fontSize).textSelection(.enabled)
        }
    }

    private var bubbleBackground: AnyShapeStyle {
        isUser ? AnyShapeStyle(model.currentAccent) : AnyShapeStyle(.quaternary.opacity(0.55))
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.content, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
            if !isUser {
                Button { model.speak(message.content) } label: { Image(systemName: "speaker.wave.2") }
                Button { model.regenerate(messageID: message.id) } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.isStreaming)
            }
            Button { model.branch(fromMessage: message.id) } label: { Image(systemName: "arrow.triangle.branch") }
            Button { model.deleteMessage(message.id) } label: { Image(systemName: "trash") }
        }
        .buttonStyle(.plain).font(.caption)
        .foregroundStyle(isUser ? .white.opacity(0.85) : .secondary)
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

