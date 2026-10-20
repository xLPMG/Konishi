import SwiftUI

struct TutorConversationView: View {
    @Environment(AppModel.self) private var appModel
    @Bindable var workspace: LanguageWorkspaceModel
    @State private var confirmDelete = false
    @State private var showTutorTrace = false
    @State private var threadPendingDeletion: LanguageTutorThread?
    @FocusState private var inputFocused: Bool

    private var selectedThread: LanguageTutorThread? {
        workspace.tutorThreads.first { $0.id == workspace.selectedTutorThreadID }
    }

    var body: some View {
        HSplitView {
            threadList
                .frame(minWidth: 200, idealWidth: 250, maxWidth: 320)
            conversation
                .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(appModel.currentPalette.canvas)
        .onAppear(perform: prepareThreads)
        .onChange(of: workspace.activeProfileID) { prepareThreads() }
        .onChange(of: appModel.voice.isListening) { _, listening in
            if !listening { appModel.voice.stopDictation() }
        }
        .sheet(isPresented: $showTutorTrace) {
            if let id = workspace.selectedTutorThreadID {
                TraceView(conversationID: id, title: "Tutor Trace")
                    .environment(appModel)
                    .tint(appModel.currentAccent)
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 8) {
                    ModelSelector()
                    if workspace.selectedTutorThreadID != nil {
                        Button { showTutorTrace = true } label: {
                            Image(systemName: "waveform.path.ecg")
                        }
                        .buttonStyle(.plain)
                        .help("Inspect this tutor thread's model requests and responses")
                    }
                    if appModel.voice.isSpeaking {
                        Button { appModel.voice.stopSpeaking() } label: {
                            Image(systemName: "speaker.slash")
                        }
                        .buttonStyle(.plain)
                        .help("Stop voice playback")
                    }
                    if workspace.isTutorStreaming {
                        Button(role: .destructive) { workspace.cancelTutorTurn() } label: {
                            Image(systemName: "stop.fill")
                        }
                        .buttonStyle(.plain)
                        .help("Stop tutor response")
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(appModel.currentPalette.surfaceRaised, in: Capsule())
                .overlay(Capsule().stroke(appModel.currentPalette.border.opacity(0.55), lineWidth: 1))
            }
        }
        .confirmationDialog(
            "Delete this tutor conversation?", isPresented: $confirmDelete, titleVisibility: .visible
        ) {
            Button("Delete Conversation", role: .destructive) {
                if let thread = threadPendingDeletion {
                    if thread.id == workspace.selectedTutorThreadID { appModel.voice.stopSpeaking() }
                    appModel.traceStore.deleteTraceFile(conversationID: thread.id)
                    workspace.deleteTutorThread(thread.id)
                }
                threadPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes this tutor conversation.")
        }
    }

    private var threadList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(workspace.activeProfile.map {
                    "Tutor threads for \($0.targetName) & \($0.baseName)"
                } ?? "Tutor threads")
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                Spacer()
                Button { workspace.createTutorThread() } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.plain)
                .help("New tutor thread")
            }
            .padding(12)
            Divider()
            List {
                ForEach(workspace.tutorThreads) { thread in
                    Button { workspace.selectTutorThread(thread.id) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(thread.title).lineLimit(2)
                            Text(threadActivityLabel(thread.updatedAt))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            threadPendingDeletion = thread
                            confirmDelete = true
                        } label: {
                            Label("Delete Conversation", systemImage: "trash")
                        }
                    }
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(workspace.selectedTutorThreadID == thread.id
                                ? appModel.currentPalette.surfaceRaised : appModel.currentPalette.surface)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(appModel.currentPalette.border, lineWidth: 1))
                    )
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(appModel.currentPalette.sidebar)
        }
        .background(appModel.currentPalette.sidebar)
    }

    @ViewBuilder private var conversation: some View {
        if let profile = workspace.activeProfile, let thread = selectedThread {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(thread.messages) { message in
                            messageRow(message, profile: profile)
                        }
                        if workspace.isTutorStreaming {
                            AssistantMessageLayout(
                                assistantName: appModel.currentAssistantName,
                                iconSymbol: appModel.currentPersona.iconSymbol,
                                accent: appModel.currentAccent,
                                surface: appModel.currentPalette.surfaceRaised,
                                border: appModel.currentPalette.border
                            ) {
                                if workspace.tutorStreamedReply.isEmpty && workspace.tutorStreamedReasoning.isEmpty {
                                    Text("Thinking…")
                                        .foregroundStyle(.secondary)
                                }
                                if !workspace.tutorStreamedReasoning.isEmpty {
                                    ReasoningDisclosureView(
                                        reasoning: workspace.tutorStreamedReasoning,
                                        isGenerating: workspace.tutorStreamedReply.isEmpty)
                                }
                                ForEach(workspace.tutorStreamedToolExchanges) { exchange in
                                    TutorToolExchangeView(exchange: exchange)
                                }
                                if !workspace.tutorStreamedReply.isEmpty {
                                    MarkdownView(
                                        text: workspace.tutorStreamedReply,
                                        baseSize: appModel.settings.fontSize
                                    )
                                    .textSelection(.enabled)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: ConversationMessageLayout.columnWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 24)
                }

                if let error = workspace.tutorError {
                    HStack(spacing: 10) {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                        Spacer(minLength: 0)
                        if workspace.failedTutorMessageID != nil {
                            Button("Retry") {
                                workspace.retryTutorMessage(
                                    config: tutorRequestConfig(), trace: recordTutorTrace)
                            }
                            .buttonStyle(.bordered)
                            .disabled(workspace.isTutorStreaming)
                        }
                    }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.top, 8)
                }
                if workspace.tutorCanContinue {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Continue this reply?")
                                .font(.callout.weight(.semibold))
                            Text(selectedThread?.messages.last?.role == .assistant
                                ? "The server stopped at its output limit."
                                : "The server stopped before returning visible text.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button("Stop") { workspace.dismissTutorContinuation() }
                            .buttonStyle(.bordered)
                        Button("Continue", action: continueTutorReply)
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                }
                inputBar(profile: profile)
            }
        } else if workspace.activeProfile == nil {
            ContentUnavailableView("Set Up a Language", systemImage: "character.book.closed",
                                   description: Text("Create a profile before starting a tutor thread."))
        } else {
            ContentUnavailableView("Start a Tutor Thread", systemImage: "bubble.left.and.bubble.right",
                                   description: Text("Tutor messages are stored separately from ordinary chats."))
        }
    }

    @ViewBuilder
    private func messageRow(_ message: LanguageTutorMessage, profile: LanguageProfile) -> some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 60)
                UserMessageBubble(accent: appModel.currentAccent) {
                    Text(message.content)
                        .font(.system(size: appModel.settings.fontSize))
                        .textSelection(.enabled)
                        .foregroundStyle(.primary)
                    MessageActionBar {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.content, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .help("Copy message")
                        Button(role: .destructive) {
                            workspace.deleteTutorMessage(message.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("Delete message")
                        .disabled(workspace.isTutorStreaming)
                    }
                }
            }
        } else {
            AssistantMessageLayout(
                assistantName: appModel.currentAssistantName,
                iconSymbol: appModel.currentPersona.iconSymbol,
                accent: appModel.currentAccent,
                surface: appModel.currentPalette.surfaceRaised,
                border: appModel.currentPalette.border
            ) {
                if let reasoning = message.reasoning,
                   !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    ReasoningDisclosureView(reasoning: reasoning)
                }
                ForEach(message.toolExchanges) { exchange in
                    TutorToolExchangeView(exchange: exchange)
                }
                MarkdownView(text: message.content, baseSize: appModel.settings.fontSize)
                    .textSelection(.enabled)
                MessageActionBar {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.content, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Copy tutor reply")
                    Button {
                        appModel.voice.speakBilingual(
                            message.content, targetLocale: profile.targetLocale, baseLocale: profile.baseLocale,
                            targetVoiceID: profile.targetVoiceID, baseVoiceID: profile.baseVoiceID,
                            rate: appModel.settings.speechRate)
                    } label: {
                        Image(systemName: "speaker.wave.2")
                    }
                    .help("Speak this tutor reply")
                    Button {
                        workspace.proposalTopic = "Useful vocabulary and natural synonyms related to: \(String(message.content.prefix(240)))"
                        workspace.destination = .study
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .help("Review vocabulary proposals from this tutor reply")
                    Button(role: .destructive) {
                        workspace.deleteTutorMessage(message.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Delete message")
                    .disabled(workspace.isTutorStreaming)
                }
            }
        }
    }

    private func inputBar(profile: LanguageProfile) -> some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 9) {
                ContextGauge(
                    used: workspace.tutorContextEstimate,
                    window: appModel.contextWindow(forModelID: appModel.settings.model),
                    isEstimate: true)

                Button { appModel.settings.reasoningEnabled.toggle() } label: {
                    Image(systemName: "brain")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(appModel.settings.reasoningEnabled
                            ? AnyShapeStyle(appModel.currentAccent) : AnyShapeStyle(.secondary))
                        .opacity(appModel.settings.reasoningEnabled ? 1 : 0.55)
                        .frame(width: 26, height: 30)
                }
                .buttonStyle(.plain)
                .disabled(workspace.isTutorStreaming)
                .help(appModel.settings.reasoningEnabled
                    ? "Reasoning on — model thinks before answering (slower). Click to turn off."
                    : "Reasoning off — faster replies. Click to turn on.")

                TextField("Message tutor", text: $workspace.tutorDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: appModel.settings.fontSize))
                    .lineLimit(1...8)
                    .padding(.vertical, 4)
                    .focused($inputFocused)
                    .onKeyPress(keys: [.return]) { keyPress in
                        if keyPress.modifiers.contains(.shift) {
                            workspace.tutorDraft.append("\n")
                            return .handled
                        }
                        send()
                        return .handled
                    }
                    .disabled(workspace.isTutorStreaming)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 5)
            .frame(minHeight: 42)
            .background(appModel.currentPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(inputFocused ? appModel.currentAccent.opacity(0.62) : appModel.currentPalette.border,
                            lineWidth: inputFocused ? 1.25 : 1)
            }
            .shadow(color: appModel.currentAccent.opacity(inputFocused ? 0.09 : 0.025),
                    radius: inputFocused ? 12 : 6, y: 3)
            .animation(.easeOut(duration: 0.16), value: inputFocused)

            dictationButton(profile: profile)

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(appModel.currentAccent, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .fixedSize()
            .layoutPriority(1)
            .disabled(workspace.tutorDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || workspace.isTutorStreaming)
            .opacity(workspace.tutorDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || workspace.isTutorStreaming ? 0.45 : 1)
            .help("Send message")
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .padding(.top, 4)
    }

    @ViewBuilder
    private func dictationButton(profile: LanguageProfile) -> some View {
        Button {
            if appModel.voice.isListening {
                appModel.voice.stopDictation()
            } else {
                startDictation(locale: profile.targetLocale)
            }
        } label: {
            Image(systemName: appModel.voice.isListening ? "mic.fill" : "mic")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(appModel.voice.isListening ? .red : .primary)
                .symbolEffect(.pulse, isActive: appModel.voice.isListening)
                .frame(width: 42, height: 42)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .layoutPriority(1)
        .background(appModel.currentPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(appModel.currentPalette.border, lineWidth: 1))
        .help(appModel.voice.isListening ? "Stop dictation" : "Dictate in \(profile.targetName)")
        .contextMenu {
            Button("Dictate in \(profile.targetName)") {
                startDictation(locale: profile.targetLocale)
            }
            Button("Dictate in \(profile.baseName)") {
                startDictation(locale: profile.baseLocale)
            }
        }
    }

    private func prepareThreads() {
        workspace.refreshTutorThreads()
    }

    private func threadActivityLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func startDictation(locale: String) {
        appModel.voice.startNativeDictation(locale: locale) { update in
            workspace.tutorDraft = update.text
        }
    }

    private func send() {
        workspace.sendTutorMessage(config: tutorRequestConfig(), trace: recordTutorTrace)
    }

    private func continueTutorReply() {
        workspace.continueTutorReply(config: tutorRequestConfig(), trace: recordTutorTrace)
    }

    private func recordTutorTrace(
        _ threadID: UUID, _ kind: TraceEntry.Kind, _ text: String, _ detail: String?
    ) {
        appModel.traceStore.trace(
            conversationID: threadID, kind: kind, text: text,
            saveTraces: appModel.settings.saveTraces, detail: detail)
    }

    private func tutorRequestConfig() -> RequestConfig {
        var config = appModel.settings.requestConfig(modelOverride: nil)
        config.enableThinking = appModel.settings.reasoningEnabled
        return config
    }
}

private struct TutorToolExchangeView: View {
    let exchange: LanguageTutorToolExchange
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: icon)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(exchange.name)
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
            .help(exchange.arguments)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    if !exchange.arguments.isEmpty && exchange.arguments != "{}" {
                        detailSection("Arguments", text: exchange.arguments)
                    }
                    detailSection("Result", text: exchange.result)
                }
                .padding(6)
                .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func detailSection(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(text.prefix(4_000))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
        }
        .padding(6)
        .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
    }

    private var icon: String {
        switch exchange.name {
        case "add_vocabulary": "text.badge.plus"
        case "language_deck_summary": "chart.bar"
        case "language_deck_list": "rectangle.stack"
        case "language_deck_search": "magnifyingglass"
        case "language_due_items": "calendar.badge.clock"
        case "language_review_history": "clock.arrow.circlepath"
        default: "wrench.and.screwdriver"
        }
    }
}