import SwiftUI
import UniformTypeIdentifiers
import PDFKit

struct ChatView: View {
    @Environment(AppModel.self) private var model
    @State private var showImporter = false
    @State private var showDocImporter = false
    @State private var showContextPins = false
    @State private var pendingChatJump: ChatJump?
    @State private var pinnedToBottom = true
    @FocusState private var inputFocused: Bool

    private struct ChatJump: Equatable {
        var requestID = UUID()
        var messageID: UUID
    }

    var body: some View {
        messageList
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if let error = model.errorMessage { errorBanner(error) }
                    if let voiceError = model.voice.lastError { voiceBanner(voiceError) }
                    if let batch = model.pendingApproval { ToolApprovalBar(batch: batch) }
                    if let gate = model.pendingWorkGate { WorkLimitBar(gate: gate) }
                    if model.isAutopilotActive || model.isStoppingWork { AutopilotStatusBar() }
                    StatsBar()
                    attachmentStrip
                    inputBar
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.15), value: model.activity)
        .navigationTitle("")
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
        var currentAssistantCreatedAt: Date?

        func flushAssistant(includePending: Bool = false) {
            guard !currentAssistantSteps.isEmpty else { return }
            let turn = AssistantTurn(
                id: currentAssistantSteps[0].id,
                createdAt: currentAssistantCreatedAt,
                steps: currentAssistantSteps,
                toolResults: currentAssistantToolResults,
                sources: currentAssistantSources,
                interrupted: currentAssistantInterrupted,
                images: currentAssistantImages,
                attachments: currentAssistantAttachments,
                allMessageIDs: currentAssistantAllIDs
            )
            let isPending = includePending
                && model.isStreaming
                && model.streamingConversationID == model.selectedConversationID
            if turn.hasVisibleContent || isPending {
                items.append(.assistant(turn))
            }
            currentAssistantSteps = []
            currentAssistantToolResults = [:]
            currentAssistantAllIDs = []
            currentAssistantSources = []
            currentAssistantInterrupted = false
            currentAssistantImages = []
            currentAssistantAttachments = []
            currentAssistantCreatedAt = nil
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
                if currentAssistantCreatedAt == nil { currentAssistantCreatedAt = msg.createdAt }
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
        flushAssistant(includePending: true)
        return items
    }

    private var datedChatItems: [ChatItem] {
        let calendar = Calendar.current
        var result: [ChatItem] = []
        var previousDay: Date?

        for item in chatItems {
            guard let timestamp = item.timestamp else {
                result.append(item)
                continue
            }
            let day = calendar.startOfDay(for: timestamp)
            if previousDay.map({ !calendar.isDate($0, inSameDayAs: day) }) ?? true {
                result.append(.dayBreak(day))
                previousDay = day
            }
            result.append(item)
        }
        return result
    }

    private var messageList: some View {
        let items = self.datedChatItems
        let activeAssistantID = model.isStreaming
            && model.streamingConversationID == model.selectedConversationID
            ? items.last(where: { $0.isAssistant })?.id
            : nil
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if items.isEmpty { emptyState }
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        switch item {
                        case .user(let message):
                            UserMessageRow(message: message)
                                .padding(.top, verticalGap(at: index, in: items))
                                .id(item.id)
                        case .assistant(let turn):
                            AssistantTurnRow(
                                turn: turn,
                                isActive: item.id == activeAssistantID,
                                onStreamUpdate: {
                                    guard pinnedToBottom else { return }
                                    withAnimation(.easeOut(duration: 0.12)) {
                                        proxy.scrollTo(item.id, anchor: .bottom)
                                    }
                                })
                                .padding(.top, verticalGap(at: index, in: items))
                                .id(item.id)
                        case .dayBreak(let day):
                            dateBreak(day)
                                .padding(.vertical, 8)
                                .id(item.id)
                        }
                    }
                }
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 18)
                .padding(.vertical, 24)
            }
            .background(model.currentPalette.canvas)
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 40
            } action: { _, atBottom in
                pinnedToBottom = atBottom
            }
            .onChange(of: model.selectedConversation?.messages.count) {
                guard pinnedToBottom, let last = items.last else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: model.selectedConversationID) {
                pinnedToBottom = true
                if let last = items.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: pendingChatJump) { _, jump in
                guard let jump, let targetID = chatItemID(containing: jump.messageID) else { return }
                pinnedToBottom = false
                withAnimation(.easeInOut(duration: 0.24)) {
                    proxy.scrollTo(targetID, anchor: .center)
                }
                pendingChatJump = nil
            }
        }
    }

    private func chatItemID(containing messageID: UUID) -> String? {
        for item in chatItems {
            switch item {
            case .user(let message) where message.id == messageID:
                return item.id
            case .assistant(let turn) where turn.allMessageIDs.contains(messageID):
                return item.id
            default:
                continue
            }
        }
        return nil
    }

    private func jumpToPinnedMessage(_ messageID: UUID) {
        showContextPins = false
        pendingChatJump = ChatJump(messageID: messageID)
    }

    private func verticalGap(at index: Int, in items: [ChatItem]) -> CGFloat {
        guard index > 0 else { return 0 }
        let previous = items[index - 1]
        if case .dayBreak = previous { return 3 }
        if items[index].isAssistant && previous.isUser { return 4 }
        if items[index].isUser && previous.isAssistant { return 18 }
        return 10
    }

    private func dateBreak(_ day: Date) -> some View {
        HStack(spacing: 12) {
            Rectangle().fill(model.currentPalette.border).frame(height: 1)
            Text(Self.dateLabel(day))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .fixedSize()
            Rectangle().fill(model.currentPalette.border).frame(height: 1)
        }
        .padding(.horizontal, 72)
        .accessibilityElement(children: .combine)
    }

    private static func dateLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .long, time: .omitted)
    }

    private var recentConversation: Conversation? {
        model.filteredConversations.first { conversation in
            guard conversation.id != model.selectedConversationID else { return false }
            return conversation.title != "New Chat"
                || conversation.lastTitledMessageCount != nil
                || conversation.updatedAt.timeIntervalSince(conversation.createdAt) > 5
        }
    }

    private var starterPrompts: [(title: String, icon: String, prompt: String)] {
        if model.mode == .language, let profile = model.activeLanguageProfile {
            let enteredTopic = model.languageSession.topic.trimmingCharacters(in: .whitespacesAndNewlines)
            let topic = enteredTopic.isEmpty ? "everyday life" : enteredTopic
            switch model.languageSession.kind {
            case .study:
                return [
                    ("Learn a phrase", "textformat.abc", "Teach me a useful \(profile.targetName) phrase about \(topic), with pronunciation and an example."),
                    ("Understand grammar", "text.book.closed", "Explain one useful \(profile.targetName) grammar point related to \(topic), with examples."),
                    ("Build vocabulary", "sparkles", "Teach me three useful \(profile.targetName) words about \(topic), one at a time.")
                ]
            case .practice:
                return [
                    ("Review due words", "checkmark.circle", "Quiz me on words due for review in \(profile.targetName). Ask one question at a time and record each answer."),
                    ("Quick quiz", "questionmark.circle", "Give me a short \(profile.targetName) quiz about \(topic), one question at a time."),
                    ("Practice a dialogue", "bubble.left.and.bubble.right", "Start a short \(profile.targetName) dialogue about \(topic) and let me respond.")
                ]
            case .free:
                return [
                    ("Start a conversation", "bubble.left.and.bubble.right", "Start a natural \(profile.targetName) conversation about \(topic). Ask me one question at a time."),
                    ("Tell a short story", "book", "Tell me a short, level-appropriate story in \(profile.targetName) about \(topic), then ask what I understood."),
                    ("Practice speaking", "waveform", "Have a relaxed spoken \(profile.targetName) conversation about \(topic), gently correcting my mistakes.")
                ]
            }
        }

        let persona = model.currentPersona
        let personaName = persona.name.lowercased()
        let personaPrompt = persona.systemPrompt.lowercased()
        if personaName.contains("coder") || personaPrompt.contains("engineering") || personaPrompt.contains("software") {
            return [
                ("Debug an issue", "ladybug", "Help me debug a coding issue. Ask me for the relevant code and exact error first."),
                ("Design a solution", "point.3.connected.trianglepath.dotted", "Help me design a simple, idiomatic solution to a programming problem."),
                ("Explain code", "curlybraces", "Explain a programming concept with a concrete example, then check my understanding.")
            ]
        }
        if persona.vaultAccessEnabled || personaName.contains("research") || personaPrompt.contains("research assistant") {
            return [
                ("Investigate a question", "magnifyingglass", "Help me investigate a question. Start by finding relevant evidence in my research notes."),
                ("Connect ideas", "point.3.connected.trianglepath.dotted", "Look for connections across my research notes about a topic I will give you."),
                ("Shape a finding", "text.alignleft", "Help me turn a research finding into a concise, well-supported note.")
            ]
        }
        if personaName.contains("muse") || personaPrompt.contains("creative") {
            return [
                ("Explore an idea", "lightbulb", "Help me explore a creative idea. Ask one question to find an interesting angle."),
                ("Find a fresh angle", "sparkles", "Give me a few unexpected angles on a creative project I will describe."),
                ("Draft something", "pencil.and.outline", "Help me shape a rough draft while keeping my voice and intent.")
            ]
        }

        return [
            ("Explore an idea", "lightbulb", "As my \(persona.name) assistant, help me explore an idea. Ask one question to get started."),
            ("Make a plan", "list.bullet", "As my \(persona.name) assistant, help me make a clear, practical plan for a goal."),
            ("Explain a topic", "sparkle.magnifyingglass", "As my \(persona.name) assistant, explain a topic with an intuitive example.")
        ]
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: model.currentPersona.iconSymbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(model.currentAccent)
                    .frame(width: 48, height: 48)
                    .background(model.currentAccent.opacity(0.13), in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 4) {
                    Text(emptyStateTitle)
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text(emptyStateSubtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(model.connectionOK == true ? Color.green : (model.connectionOK == false ? Color.orange : Color.secondary))
                    .frame(width: 7, height: 7)
                Text(model.connectionOK == true ? "Model connected" : (model.connectionOK == false ? "Check model connection" : "Checking model…"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if let recentConversation {
                Button {
                    model.selectedConversationID = recentConversation.id
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(model.currentAccent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Continue recent conversation")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Text(recentConversation.title)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Return to \(recentConversation.title)")
            }

            HStack(spacing: 8) {
                ForEach(starterPrompts.indices, id: \.self) { index in
                    let suggestion = starterPrompts[index]
                    starterButton(suggestion.title, icon: suggestion.icon, prompt: suggestion.prompt)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 660, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 72)
    }

    private var emptyStateTitle: String {
        if model.mode == .language, let profile = model.activeLanguageProfile {
            return "A little more \(profile.targetName) today."
        }
        return "A little room to think."
    }

    private var emptyStateSubtitle: String {
        if model.mode == .language, let profile = model.activeLanguageProfile {
            return "\(model.languageSession.kind.label) with \(model.currentAssistantName), at \(profile.level.code)."
        }
        return "Start a conversation with \(model.currentAssistantName)."
    }

    private func starterButton(_ title: String, icon: String, prompt: String) -> some View {
        Button {
            model.draft = prompt
            inputFocused = true
        } label: {
            Label(title, systemImage: icon)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private func errorBanner(_ text: String) -> some View {
        banner(text, symbol: "exclamationmark.triangle.fill", tint: .orange) { model.errorMessage = nil }
    }

    private func voiceBanner(_ text: String) -> some View {
        banner(text, symbol: "mic.slash.fill", tint: .red) { model.voice.lastError = nil }
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
        return HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 9) {
                Menu {
                    Button { showImporter = true } label: { Label("Image…", systemImage: "photo") }
                    Button { showDocImporter = true } label: { Label("PDF or Text File…", systemImage: "doc") }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 44, height: 42)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Attach image or file")

                ContextGauge(used: model.selectedConversation?.lastStats?.promptTokens ?? 0, window: model.contextWindow)
                if !model.selectedContextPins.isEmpty {
                    contextPinsControl
                }

                Button { model.settings.reasoningEnabled.toggle() } label: {
                    Image(systemName: "brain")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(model.settings.reasoningEnabled ? AnyShapeStyle(model.currentAccent) : AnyShapeStyle(.secondary))
                        .opacity(model.settings.reasoningEnabled ? 1 : 0.55)
                        .frame(width: 26, height: 30)
                }
                .buttonStyle(.plain)
                .help(model.settings.reasoningEnabled ? "Reasoning on — model thinks before answering (slower). Click to turn off." : "Reasoning off — faster replies. Click to turn on.")

                TextField("Message \(model.currentAssistantName)…", text: $model.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: model.settings.fontSize))
                    .lineLimit(1...8)
                    .padding(.vertical, 4)
                    .focused($inputFocused)
                    .onKeyPress(keys: [.return]) { keyPress in
                        if keyPress.modifiers.contains(.shift) {
                            model.draft.append("\n")
                            return .handled
                        }
                        model.send()
                        return .handled
                    }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 5)
            .frame(minHeight: 42)
            .background(model.currentPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(inputFocused ? model.currentAccent.opacity(0.62) : model.currentPalette.border, lineWidth: inputFocused ? 1.25 : 1)
            }
            .shadow(color: model.currentAccent.opacity(inputFocused ? 0.09 : 0.025), radius: inputFocused ? 12 : 6, y: 3)
            .animation(.easeOut(duration: 0.16), value: inputFocused)

            Button { model.toggleDictation() } label: {
                Image(systemName: model.voice.isListening ? "mic.fill" : "mic")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(model.voice.isListening ? .red : .primary)
                    .symbolEffect(.pulse, isActive: model.voice.isListening)
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .background(model.currentPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.currentPalette.border, lineWidth: 1))
            .help("Dictate")

            Button { model.send() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(model.currentAccent, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(!model.canSend)
            .opacity(model.canSend ? 1 : 0.45)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .frame(maxWidth: 860)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .padding(.top, 4)
    }

    private var contextPinsControl: some View {
        let pins = model.selectedContextPins
        return Button { showContextPins.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: pins.isEmpty ? "pin" : "pin.fill")
                if !pins.isEmpty {
                    Text("\(pins.count)")
                        .font(.caption2.monospacedDigit())
                }
            }
            .foregroundStyle(pins.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(model.currentAccent))
            .frame(minWidth: 26, minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Pinned context (\(pins.count)/\(ContextPin.maximumCount))")
        .popover(isPresented: $showContextPins, arrowEdge: .bottom) {
            contextPinsPopover
        }
    }

    private var contextPinsPopover: some View {
        let pins = model.selectedContextPins
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Pinned context", systemImage: "pin.fill")
                    .font(.headline)
                Spacer()
                Text("\(pins.count)/\(ContextPin.maximumCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if pins.isEmpty {
                Text("No pinned messages")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(pins) { pin in
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(pin.role == .user ? "You" : "Assistant")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(pin.text)
                                        .font(.caption)
                                        .lineLimit(4)
                                        .textSelection(.enabled)
                                }
                                Spacer(minLength: 0)
                                Button { jumpToPinnedMessage(pin.messageID) } label: {
                                    Image(systemName: "arrow.up.left")
                                        .font(.caption.weight(.semibold))
                                        .frame(width: 22, height: 22)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Jump to message")
                                Button { model.removeContextPin(pin.messageID) } label: {
                                    Image(systemName: "xmark")
                                        .font(.caption.weight(.semibold))
                                        .frame(width: 22, height: 22)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Remove pin")
                            }
                            if pin.id != pins.last?.id { Divider() }
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
            Divider()
            Text("Each pin keeps up to \(ContextPin.maximumPinCharacters) characters from its message.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 320)
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
            approvalCalls
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

    @ViewBuilder
    private var approvalCalls: some View {
        if batch.calls.count > 2 {
            ScrollView {
                callRows
            }
            .frame(height: 100)
        } else {
            callRows
        }
    }

    private var callRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(batch.calls) { call in
                ToolApprovalItem(call: call)
            }
        }
    }
}

private struct ToolApprovalItem: View {
    let call: ToolCall
    @State private var argumentsExpanded = false

    private var name: String { call.function.name ?? "tool" }

    private var summary: String {
        guard let data = call.function.arguments.data(using: .utf8),
              let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return name }
        for key in ["path", "note", "url", "query", "expression", "command"] {
            if let value = arguments[key] as? String, !value.isEmpty {
                return "\(name) · \(value)"
            }
        }
        return name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(summary, systemImage: name == "run_shell" ? "terminal" : "wrench.and.screwdriver")
                .font(.caption.monospaced())
                .lineLimit(2)
                .textSelection(.enabled)

            if !call.function.arguments.isEmpty, call.function.arguments != "{}" {
                DisclosureGroup("Full arguments", isExpanded: $argumentsExpanded) {
                    ScrollView {
                        Text(call.function.arguments)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                    .frame(maxHeight: 110)
                    .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                }
                .font(.caption2)
            }
        }
        .padding(6)
        .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct WorkLimitBar: View {
    @Environment(AppModel.self) private var model
    let gate: AppModel.PendingWorkGate

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Continue working?", systemImage: "hourglass")
                .font(.callout.weight(.semibold))
            Text(gate.reason.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Continue") { model.continueAgentWork() }
                    .buttonStyle(.borderedProminent)
                Button("Stop", role: .destructive) { model.stopAgentWork() }
                Spacer()
            }
        }
        .padding(10)
        .background(model.currentAccent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

private struct AutopilotStatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Label(
                model.isStoppingWork ? "Stopping after current tool…" : "Autopilot active",
                systemImage: model.isStoppingWork ? "hourglass" : "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(model.currentAccent)
            Text(model.isStoppingWork ? "The current tool operation must finish first." : "Only auto-approved tools are available.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
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
    let createdAt: Date?
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
    case dayBreak(Date)

    var id: String {
        switch self {
        case .user(let msg): return "message-\(msg.id.uuidString)"
        case .assistant(let turn): return "turn-\(turn.id.uuidString)"
        case .dayBreak(let date): return "day-\(Int(date.timeIntervalSince1970))"
        }
    }

    var timestamp: Date? {
        switch self {
        case .user(let message): message.createdAt
        case .assistant(let turn): turn.createdAt
        case .dayBreak: nil
        }
    }

    var isUser: Bool {
        if case .user = self { return true }
        return false
    }

    var isAssistant: Bool {
        if case .assistant = self { return true }
        return false
    }
}

private struct UserMessageRow: View {
    @Environment(AppModel.self) private var model
    let message: ChatMessage
    @State private var zoom: IdentifiableImage?

    var body: some View {
        HStack {
            Spacer(minLength: 60)
            VStack(alignment: .leading, spacing: 6) {
                Label("You", systemImage: "person.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(model.currentAccent)
                if !message.images.isEmpty { imageGrid }
                if !message.attachments.isEmpty { attachmentChips }
                Text(message.content)
                    .font(.system(size: model.settings.fontSize))
                    .textSelection(.enabled)
                    .foregroundStyle(.primary)
                actions
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(model.currentAccent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(model.currentAccent.opacity(0.16), lineWidth: 1)
            }
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(model.currentAccent)
                    .frame(width: 3)
                    .padding(.vertical, 12)
            }
        }
        .sheet(item: $zoom) { ZoomImageView(image: $0.image) }
        .contextMenu {
            Button("Copy Message", systemImage: "doc.on.doc") { copyMessage() }
            Button(
                model.isContextPinned(message.id) ? "Remove from Pinned Context" : "Pin to Context",
                systemImage: model.isContextPinned(message.id) ? "pin.slash" : "pin"
            ) { model.toggleContextPin(message.id) }
            .disabled(pinActionDisabled)
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
            Button { model.toggleContextPin(message.id) } label: {
                Image(systemName: model.isContextPinned(message.id) ? "pin.fill" : "pin")
            }
            .help(model.isContextPinned(message.id) ? "Remove from pinned context" : "Pin to context")
            .disabled(pinActionDisabled)
            Button { copyMessage() } label: { Image(systemName: "doc.on.doc") }
            Button { model.branch(fromMessage: message.id) } label: { Image(systemName: "arrow.triangle.branch") }
            Button { model.deleteMessage(message.id) } label: { Image(systemName: "trash") }
        }
        .buttonStyle(.plain).font(.caption)
        .foregroundStyle(.secondary)
    }

    private var pinActionDisabled: Bool {
        if model.isContextPinned(message.id) { return false }
        return model.selectedContextPins.count >= ContextPin.maximumCount
            || message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
    }
}

private struct AssistantTurnRow: View {
    @Environment(AppModel.self) private var model
    let turn: AssistantTurn
    let isActive: Bool
    let onStreamUpdate: () -> Void
    @State private var zoom: IdentifiableImage?

    private var visibleSteps: [AssistantStep] {
        var visibleSteps = turn.steps.filter(\.hasVisibleContent)
        if isActive, let activeStep = turn.steps.last,
            !visibleSteps.contains(where: { $0.id == activeStep.id })
        {
            visibleSteps.append(activeStep)
        }
        return visibleSteps
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: model.currentPersona.iconSymbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(model.currentAccent)
                .frame(width: 30, height: 30)
                .background(model.currentPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(model.currentPalette.border, lineWidth: 1))
            VStack(alignment: .leading, spacing: 8) {
                Text(model.currentAssistantName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if !turn.images.isEmpty { imageGrid }
                if !turn.attachments.isEmpty { attachmentChips }

                let reasoningCount = turn.steps.filter { !($0.reasoning?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }.count

                ForEach(Array(visibleSteps.enumerated()), id: \.element.id) { idx, step in
                    if isActive, step.id == turn.steps.last?.id {
                        LiveAssistantStepView(
                            step: step,
                            toolResults: turn.toolResults,
                            presentation: model.streamPresentation,
                            baseSize: model.settings.fontSize,
                            sources: turn.sources,
                            onStreamUpdate: onStreamUpdate
                        )
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            if let reasoning = step.reasoning,
                               !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                let title = reasoningCount > 1 ? "Reasoning (Step \(idx + 1))" : "Reasoning"
                                ReasoningDisclosureView(reasoning: reasoning, title: title)
                            }
                            if !step.content.isEmpty {
                                MarkdownView(
                                    text: step.content,
                                    baseSize: model.settings.fontSize,
                                    sources: turn.sources
                                )
                                    .textSelection(.enabled)
                            }
                            if let toolCalls = step.toolCalls, !toolCalls.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(toolCalls) { call in
                                        ToolCallView(
                                            call: call,
                                            result: turn.toolResults[call.id],
                                            sources: turn.sources
                                        )
                                    }
                                }
                            }
                        }
                    }
                }

                if isActive, let activity = model.activity {
                    AssistantActivityView(text: activity)
                        .transition(.opacity)
                }

                if turn.interrupted {
                    Label("Interrupted", systemImage: "waveform.badge.minus")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if !turn.sources.isEmpty { sourcesView }
                actions
            }
            .frame(maxWidth: 960, alignment: .leading)
            Spacer(minLength: 20)
        }
        .sheet(item: $zoom) { ZoomImageView(image: $0.image) }
        .contextMenu {
            Button("Copy Message", systemImage: "doc.on.doc") { copyTurn() }
            if let pinnableStep {
                Button(
                    model.isContextPinned(pinnableStep.id) ? "Remove from Pinned Context" : "Pin to Context",
                    systemImage: model.isContextPinned(pinnableStep.id) ? "pin.slash" : "pin"
                ) { model.toggleContextPin(pinnableStep.id) }
                .disabled(isActive || pinActionDisabled(for: pinnableStep.id))
            }
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
            if let pinnableStep {
                Button { model.toggleContextPin(pinnableStep.id) } label: {
                    Image(systemName: model.isContextPinned(pinnableStep.id) ? "pin.fill" : "pin")
                }
                .help(model.isContextPinned(pinnableStep.id) ? "Remove from pinned context" : "Pin to context")
                .disabled(isActive || pinActionDisabled(for: pinnableStep.id))
            }
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

    private var pinnableStep: AssistantStep? {
        turn.steps.last {
            !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func pinActionDisabled(for messageID: UUID) -> Bool {
        !model.isContextPinned(messageID)
            && model.selectedContextPins.count >= ContextPin.maximumCount
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

private struct LiveAssistantStepView: View {
    let step: AssistantStep
    let toolResults: [String: String]
    let presentation: StreamPresentation
    let baseSize: Double
    let sources: [Source]
    let onStreamUpdate: () -> Void

    var body: some View {
        let isCurrent = presentation.assistantID == step.id
        let content = step.content + (isCurrent ? presentation.content : "")
        let reasoning = (step.reasoning ?? "") + (isCurrent ? presentation.reasoning : "")

        VStack(alignment: .leading, spacing: 6) {
            if !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ReasoningDisclosureView(reasoning: reasoning, title: "Reasoning")
            }
            if !content.isEmpty {
                Text(content)
                    .font(.system(size: baseSize))
                    .textSelection(.enabled)
            }
            if let toolCalls = step.toolCalls, !toolCalls.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(toolCalls) { call in
                        ToolCallView(
                            call: call,
                            result: toolResults[call.id],
                            sources: sources
                        )
                    }
                }
            }
        }
        .onChange(of: presentation.content) { onStreamUpdate() }
        .onChange(of: presentation.reasoning) { onStreamUpdate() }
    }
}

private struct AssistantActivityView: View {
    let text: String
    @State private var isAnimating = false

    private var displayText: String {
        let label: String
        if text.hasSuffix("…") {
            label = String(text.dropLast())
        } else if text.hasSuffix("...") {
            label = String(text.dropLast(3))
        } else {
            label = text
        }
        return label == "Thinking" ? "" : label
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 4, height: 4)
                        .opacity(isAnimating ? 0.35 : 0.9)
                        .offset(y: isAnimating ? 1 : -1)
                        .animation(
                            .easeInOut(duration: 0.55).repeatForever().delay(Double(index) * 0.14),
                            value: isAnimating
                        )
                }
            }
            .accessibilityHidden(true)

            if !displayText.isEmpty {
                Text(displayText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(displayText.isEmpty ? "Thinking" : displayText)
        .onAppear { isAnimating = true }
    }
}

private struct ReasoningDisclosureView: View {
    @Environment(AppModel.self) private var model
    let reasoning: String
    var title: String = "Reasoning"
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            HStack(alignment: .top, spacing: 8) {
                model.currentPalette.border
                    .frame(width: 1)
                Text(reasoning)
                    .font(.system(size: max(11, model.settings.fontSize - 2)))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
                .padding(.top, 4)
        } label: {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

private struct ToolCallView: View {
    let call: ToolCall
    let result: String?
    let sources: [Source]
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
                            if let artifact = ToolArtifact.make(
                                toolName: call.function.name ?? "",
                                arguments: call.function.arguments,
                                result: result,
                                sources: sources
                            ) {
                                ToolArtifactView(artifact: artifact)
                            } else {
                                ScrollView {
                                    Text(result.prefix(4000))
                                        .font(.system(size: 11, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 120)
                            }
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
        case "conversation_search", "conversation_list", "conversation_read": return "clock.arrow.circlepath"
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

private struct ToolArtifactView: View {
    let artifact: ToolArtifact
    @State private var copied = false

    var body: some View {
        switch artifact {
        case let .calculation(expression, value, isError):
            VStack(alignment: .leading, spacing: 5) {
                Text(expression)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(value)
                        .font(.system(size: 17, weight: .semibold, design: .monospaced))
                        .foregroundStyle(isError ? Color.red : Color.primary)
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    copyButton(value)
                }
            }
        case let .process(exitCode, output):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(
                        exitCode == 0 ? "Completed" : "Exit \(exitCode)",
                        systemImage: exitCode == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(exitCode == 0 ? Color.green : Color.red)
                    Spacer()
                    copyButton(output)
                }
                ScrollView([.horizontal, .vertical]) {
                    Text(output.isEmpty ? "(no output)" : output)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                .frame(maxHeight: 160)
                .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            }
        case let .sources(sources):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                    if let url = URL(string: source.url) {
                        Link(destination: url) {
                            HStack(alignment: .top, spacing: 7) {
                                Text("\(index + 1)")
                                    .font(.caption2.weight(.bold).monospacedDigit())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.title.isEmpty ? source.url : source.title)
                                        .font(.caption)
                                        .lineLimit(2)
                                    Text(url.host ?? source.url)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.forward.app")
                                    .font(.caption2)
                            }
                            .foregroundStyle(.blue)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func copyButton(_ text: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.caption2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(copied ? "Copied" : "Copy result")
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

