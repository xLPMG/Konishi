import SwiftUI
import Charts
import UniformTypeIdentifiers
import PDFKit

struct ChatView: View {
    @Environment(AppModel.self) private var model
    @State private var showImporter = false
    @State private var showDocImporter = false
    @State private var showContextPins = false
    @State private var activeStarterBrief: StarterBriefKind?
    @State private var pendingChatJump: ChatJump?
    @State private var pinnedToBottom = true
    @FocusState private var inputFocused: Bool

    private struct ChatJump: Equatable {
        var requestID = UUID()
        var messageID: UUID
    }

    private enum StarterBriefKind: String, Identifiable, Equatable {
        case research
        case decision
        case idea

        var id: String { rawValue }

        var title: String {
            switch self {
            case .research: "Build a research brief"
            case .decision: "Help me make a decision"
            case .idea: "Develop an idea"
            }
        }

        var icon: String {
            switch self {
            case .research: "doc.text.magnifyingglass"
            case .decision: "arrow.triangle.branch"
            case .idea: "lightbulb"
            }
        }

        var introduction: String {
            switch self {
            case .research: "Set the question, evidence, scope, and what the answer needs to help you do."
            case .decision: "Lay out the options, stakes, priorities, and constraints."
            case .idea: "Share the audience, goal, current state, and constraints so the next step fits your situation."
            }
        }

        var subjectLabel: String {
            switch self {
            case .research: "Research question or topic"
            case .decision: "What decision are you facing?"
            case .idea: "What is the idea?"
            }
        }

        var goalLabel: String {
            switch self {
            case .research: "What do you need to understand or decide?"
            case .decision: "What options are on the table?"
            case .idea: "Who is it for, and what should it achieve?"
            }
        }

        var contextLabel: String {
            switch self {
            case .research: "What do you already know or suspect?"
            case .decision: "What matters most to you? Rank priorities if you can."
            case .idea: "What exists so far? What have you tried?"
            }
        }

        var constraintsLabel: String {
            switch self {
            case .research: "Scope, timeframe, or sources to include or exclude"
            case .decision: "Constraints, deadline, risks, or what cannot be changed"
            case .idea: "Constraints: time, budget, tools, or requirements"
            }
        }

        var outcomeLabel: String {
            switch self {
            case .research: "What would a useful result look like?"
            case .decision: "What would make the choice feel clear?"
            case .idea: "What help do you need next: critique, options, plan, or draft?"
            }
        }

        func prompt(subject: String, goal: String, context: String, constraints: String, outcome: String) -> String {
            let details = [
                (subjectLabel, subject),
                (goalLabel, goal),
                (contextLabel, context),
                (constraintsLabel, constraints),
                (outcomeLabel, outcome)
            ]
            .filter { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "\($0.0): \($0.1.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .joined(separator: "\n")

            switch self {
            case .research:
                return """
                Help me investigate this research brief. Use available research tools and provided source material where relevant; ground claims in sources, distinguish evidence from inference, and never invent citations. If no sources are available, say so and ask me for material rather than simulating a sourced review. Identify important uncertainty and give me a useful synthesis with next steps. Ask a targeted clarification only if an ambiguity would materially change the result.

                \(details)
                """
            case .decision:
                return """
                Help me reason through this decision using my priorities and constraints, not generic pros and cons. Compare the options against the criteria I gave, distinguish facts from assumptions, consider risks and reversibility, and recommend a path with clear rationale. Explain what missing information could change the recommendation. If critical context is missing, ask focused questions before recommending.

                \(details)
                """
            case .idea:
                return """
                Help me develop this idea using the goals, audience, context, and constraints below. Avoid generic brainstorming: identify the main opportunity and risks, offer a few meaningfully different options where useful, recommend a practical next step, and state any assumptions that affect the recommendation.

                \(details)
                """
            }
        }
    }

    private enum StarterAction {
        case draft(String)
        case send(String)
        case brief(StarterBriefKind)
    }

    private struct StarterPrompt: Identifiable {
        let title: String
        let detail: String
        let icon: String
        let action: StarterAction

        var id: String { title }
    }

    private struct StarterBriefSheet: View {
        @Environment(\.dismiss) private var dismiss
        let kind: StarterBriefKind
        let onPrepare: (String) -> Void

        @State private var subject = ""
        @State private var goal = ""
        @State private var context = ""
        @State private var constraints = ""
        @State private var outcome = ""

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: kind.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.tint)
                        .frame(width: 38, height: 38)
                        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(kind.title).font(.title3.weight(.semibold))
                        Text(kind.introduction).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 18)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        briefField(kind.subjectLabel, text: $subject)
                        briefField(kind.goalLabel, text: $goal)
                        briefField(kind.contextLabel, text: $context)
                        briefField(kind.constraintsLabel, text: $constraints)
                        briefField(kind.outcomeLabel, text: $outcome)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    Button("Cancel", role: .cancel) { dismiss() }
                    Spacer()
                    Button {
                        onPrepare(kind.prompt(
                            subject: subject,
                            goal: goal,
                            context: context,
                            constraints: constraints,
                            outcome: outcome
                        ))
                        dismiss()
                    } label: {
                        Label("Add brief to composer", systemImage: "arrow.down.to.line")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.top, 18)
            }
            .padding(24)
            .frame(minWidth: 500, idealWidth: 560, minHeight: 560, idealHeight: 660)
        }

        private func briefField(_ label: String, text: Binding<String>) -> some View {
            VStack(alignment: .leading, spacing: 5) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField(label, text: text, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
            }
        }
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
                    if model.queuedTextInterrupt != nil {
                        Label("Queued until the current tool finishes", systemImage: "hourglass")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .alignedToChatColumn(alignment: .leading)
                            .padding(.vertical, 4)
                    }
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
        .sheet(item: $activeStarterBrief) { kind in
            StarterBriefSheet(kind: kind) { prompt in
                model.draft = prompt
                inputFocused = true
            }
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
        var currentAssistantWebImageResults: [WebImageResult] = []
        var currentAssistantAllIDs: [UUID] = []
        var currentAssistantSources: [Source] = []
        var currentAssistantSuggestions: [MessageSuggestion] = []
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
                webImageResults: currentAssistantWebImageResults,
                sources: currentAssistantSources,
                suggestions: currentAssistantSuggestions,
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
            currentAssistantWebImageResults = []
            currentAssistantAllIDs = []
            currentAssistantSources = []
            currentAssistantSuggestions = []
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
                for suggestion in msg.suggestions where !currentAssistantSuggestions.contains(where: { $0.id == suggestion.id }) {
                    currentAssistantSuggestions.append(suggestion)
                }
                if msg.interrupted { currentAssistantInterrupted = true }
                if !msg.images.isEmpty { currentAssistantImages.append(contentsOf: msg.images) }
                if !msg.attachments.isEmpty { currentAssistantAttachments.append(contentsOf: msg.attachments) }
            case .tool:
                currentAssistantAllIDs.append(msg.id)
                if let callId = msg.toolCallId {
                    currentAssistantToolResults[callId] = msg.content
                }
                currentAssistantWebImageResults.append(contentsOf: msg.webImageResults)
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
                    Color.clear
                        .frame(height: 1)
                        .id("chat-top")
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
                .frame(maxWidth: ConversationMessageLayout.columnWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
            }
                .id(model.selectedConversationID)
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
                if let last = datedChatItems.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                } else {
                    proxy.scrollTo("chat-top", anchor: .top)
                }
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

    private var starterPrompts: [StarterPrompt] {
        var prompts: [StarterPrompt] = []
        if model.mode == .chat {
            let enabledTools = enabledStarterTools
            if enabledTools.contains("calendar_events") {
                prompts.append(StarterPrompt(
                    title: "Check my calendar",
                    detail: "Send now · summarize the next seven days",
                    icon: "calendar",
                    action: .send("Review my calendar from today through the next seven days. Group events by date with start times and calendar names, flag overlaps, and point out clear open blocks. Keep the summary concise.")
                ))
            }
            prompts.append(StarterPrompt(
                title: "Build a research brief",
                detail: "Set the question, evidence, scope, and intended use",
                icon: "doc.text.magnifyingglass",
                action: .brief(.research)
            ))
            prompts.append(StarterPrompt(
                title: "Develop an idea",
                detail: "Add your audience, goal, context, and constraints",
                icon: "lightbulb",
                action: .brief(.idea)
            ))
            prompts.append(StarterPrompt(
                title: "Help me make a decision",
                detail: "Compare options using your priorities and constraints",
                icon: "arrow.triangle.branch",
                action: .brief(.decision)
            ))
            return Array(prompts.prefix(4))
        }

        let persona = model.currentPersona
        let personaName = persona.name.lowercased()
        let personaPrompt = persona.systemPrompt.lowercased()
        if personaName.contains("coder") || personaPrompt.contains("engineering") || personaPrompt.contains("software") {
            prompts += [
                StarterPrompt(title: "Debug an issue", detail: "Start with the code and exact error", icon: "ladybug", action: .draft("Help me debug a coding issue. Ask me for the relevant code and exact error first.")),
                StarterPrompt(title: "Design a solution", detail: "Keep it simple and idiomatic", icon: "point.3.connected.trianglepath.dotted", action: .draft("Help me design a simple, idiomatic solution to a programming problem.")),
                StarterPrompt(title: "Explain code", detail: "Use an example, then check my understanding", icon: "curlybraces", action: .draft("Explain a programming concept with a concrete example, then check my understanding."))
            ]
        } else if personaName.contains("research") || personaPrompt.contains("research assistant") {
            prompts += [
                StarterPrompt(title: "Investigate a question", detail: "Break it into useful sub-questions", icon: "magnifyingglass", action: .draft("Help me break down a question into useful sub-questions and suggest what evidence would answer it.")),
                StarterPrompt(title: "Connect ideas", detail: "I will give you the topic", icon: "point.3.connected.trianglepath.dotted", action: .draft("Look for connections between ideas about a topic I will give you.")),
                StarterPrompt(title: "Shape a finding", detail: "Turn a finding I provide into a clear note", icon: "text.alignleft", action: .draft("Help me turn a research finding I provide into a concise, well-supported note."))
            ]
        } else if personaName.contains("muse") || personaPrompt.contains("creative") {
            prompts += [
                StarterPrompt(title: "Explore an idea", detail: "Find an interesting angle", icon: "lightbulb", action: .draft("Help me explore a creative idea. Ask one question to find an interesting angle.")),
                StarterPrompt(title: "Find a fresh angle", detail: "Offer a few unexpected directions", icon: "sparkles", action: .draft("Give me a few unexpected angles on a creative project I will describe.")),
                StarterPrompt(title: "Draft something", detail: "Keep my voice and intent", icon: "pencil.and.outline", action: .draft("Help me shape a rough draft while keeping my voice and intent."))
            ]
        } else {
            prompts += [
                StarterPrompt(title: "Explore an idea", detail: "Start with one useful question", icon: "lightbulb", action: .draft("As my \(persona.name) assistant, help me explore an idea. Ask one question to get started.")),
                StarterPrompt(title: "Make a plan", detail: "Turn a goal into practical next steps", icon: "list.bullet", action: .draft("As my \(persona.name) assistant, help me make a clear, practical plan for a goal.")),
                StarterPrompt(title: "Explain a topic", detail: "Build intuition with an example", icon: "sparkle.magnifyingglass", action: .draft("As my \(persona.name) assistant, explain a topic with an intuitive example."))
            ]
        }

        return prompts
    }

    private var enabledStarterTools: Set<String> {
        guard model.settings.toolsEnabled(for: model.mode) else { return [] }
        let enabled = model.settings.enabledTools(for: model.mode)
        return model.currentPersona.vaultAccessEnabled
            ? enabled
            : enabled.subtracting(Tools.vaultToolNames)
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

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(starterPrompts.indices, id: \.self) { index in
                    starterButton(starterPrompts[index])
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 660, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 72)
    }

    private var emptyStateTitle: String {
        return "A little room to think."
    }

    private var emptyStateSubtitle: String {
        return "Start a conversation with \(model.currentAssistantName)."
    }

    private func starterButton(_ suggestion: StarterPrompt) -> some View {
        Button {
            switch suggestion.action {
            case .draft(let prompt):
                model.draft = prompt
                inputFocused = true
            case .send(let prompt):
                model.draft = prompt
                model.send()
            case .brief(let kind):
                activeStarterBrief = kind
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: suggestion.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(model.currentAccent)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(suggestion.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(suggestion.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .help(suggestion.detail)
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
        .padding(.top, 8)
        .alignedToChatColumn()
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
            .alignedToChatColumn()
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
            .fixedSize()
            .layoutPriority(1)
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
            .fixedSize()
            .layoutPriority(1)
            .disabled(!model.canSend)
            .opacity(model.canSend ? 1 : 0.45)
            .help(model.canInterruptWithText ? "Interrupt reply and send message" : model.canQueueTextInterrupt ? "Queue message until the current tool finishes" : "Send message")
            .keyboardShortcut(.return, modifiers: .command)
        }
        .disabled(model.queuedTextInterrupt != nil)
        .alignedToChatColumn()
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

    private var askedCalls: [ToolCall] {
        batch.calls.filter { batch.permissionEvaluations[$0.id]?.verdict == .ask }
    }

    private var permissionMode: AppMode { batch.permissionMode ?? model.mode }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Permission needed for \(askedCalls.count) tool call(s)", systemImage: "wrench.and.screwdriver.fill")
                .font(.callout.weight(.semibold))
            approvalCalls
            Text("Other permitted calls will still run; denied calls will not.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Approve Once") { model.approveTools() }.buttonStyle(.borderedProminent)
                if model.canRememberPendingTools() {
                    Menu {
                        Button("In this conversation · this folder") {
                            model.rememberPendingTools(inConversation: true, anywhere: false)
                        }
                        Button("In this conversation · anywhere") {
                            model.rememberPendingTools(inConversation: true, anywhere: true)
                        }
                        Divider()
                        Button("Always (\(permissionMode.label) mode) · this folder") {
                            model.rememberPendingTools(inConversation: false, anywhere: false)
                        }
                        Button("Always (\(permissionMode.label) mode) · anywhere") {
                            model.rememberPendingTools(inConversation: false, anywhere: true)
                        }
                    } label: {
                        Label("Remember", systemImage: "bookmark")
                    }
                    .help("Create the capability rules previewed on each requested effect.")
                }
                Button("Deny") { model.denyTools() }
                Spacer()
            }
        }
        .padding(10)
        .background(model.currentAccent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        .padding(.top, 8)
        .alignedToChatColumn()
    }

    @ViewBuilder
    private var approvalCalls: some View {
        if askedCalls.count > 2 {
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
            ForEach(askedCalls) { call in
                if let evaluation = batch.permissionEvaluations[call.id] {
                    ToolApprovalItem(
                        call: call, evaluation: evaluation,
                        workspace: Paths.conversationFiles(batch.conversationID), mode: permissionMode)
                }
            }
        }
    }
}

private struct ToolApprovalItem: View {
    let call: ToolCall
    let evaluation: ToolPermissionEvaluation
    let workspace: URL
    let mode: AppMode
    @State private var argumentsExpanded = false

    private var name: String { call.function.name ?? "tool" }
    private var askedEffects: [EffectEvaluation] {
        evaluation.effects.filter { $0.decision == .ask }
    }

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

            ForEach(askedEffects.indices, id: \.self) { index in
                effectRow(askedEffects[index])
            }
            if askedEffects.isEmpty, let explanation = evaluation.explanation {
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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

    @ViewBuilder
    private func effectRow(_ value: EffectEvaluation) -> some View {
        let capability = value.effect.capability
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Label(effectLabel(value.effect), systemImage: riskSymbol(capability.risk))
                    .font(.caption)
                    .foregroundStyle(riskColor(capability.risk))
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                Text(capability.risk.rawValue.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(riskColor(capability.risk))
            }
            if let path = value.effect.path,
               let reason = ProtectedLocations.reason(for: path, workspace: workspace)
            {
                Label("\(reason) Approve Once is the only saved-choice option.", systemImage: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Conversation rule: \(capability.rawValue) · \(ruleScope(value.effect))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("\(mode.label) mode rule: \(capability.rawValue) · \(ruleScope(value.effect))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.leading, 4)
    }

    private func effectLabel(_ effect: PermissionEffect) -> String {
        guard let path = effect.path else { return effect.capability.label }
        let location = displayedPath(path)
        return switch effect.capability {
        case .workspaceRead: "Read workspace · \(location)"
        case .workspaceWrite: "Write workspace · \(location)"
        case .externalRead: "Read file · outside workspace · \(location)"
        case .externalWrite: "Write file · outside workspace · \(location)"
        default: "\(effect.capability.label) · \(location)"
        }
    }

    private func displayedPath(_ path: String) -> String {
        let workspacePath = PathScope.canonicalPath(workspace.path)
        let canonicalPath = PathScope.canonicalPath(path)
        if PathScope.path(canonicalPath, isWithin: workspacePath) {
            let relative = String(canonicalPath.dropFirst(workspacePath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return relative.isEmpty ? "." : relative
        }
        let homePath = PathScope.canonicalPath(FileManager.default.homeDirectoryForCurrentUser.path)
        if PathScope.path(canonicalPath, isWithin: homePath) {
            return "~" + canonicalPath.dropFirst(homePath.count)
        }
        return canonicalPath
    }

    private func ruleScope(_ effect: PermissionEffect) -> String {
        guard let path = effect.path else { return "any" }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return "pathPrefix(\(parent))"
    }

    private func riskSymbol(_ risk: Capability.Risk) -> String {
        switch risk {
        case .low: "checkmark.circle"
        case .medium: "exclamationmark.circle"
        case .high: "exclamationmark.triangle.fill"
        }
    }

    private func riskColor(_ risk: Capability.Risk) -> Color {
        switch risk {
        case .low: .secondary
        case .medium: .orange
        case .high: .red
        }
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
        .padding(.top, 8)
        .alignedToChatColumn()
    }
}

private struct AutopilotStatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label(
                    model.isStoppingWork ? "Stopping after current tool…" : "Autopilot active",
                    systemImage: model.isStoppingWork ? "hourglass" : "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(model.currentAccent)
                Spacer()
            }
            AutopilotPermissionSummary(compact: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .alignedToChatColumn()
    }
}

private extension View {
    func alignedToChatColumn(alignment: Alignment = .center) -> some View {
        frame(maxWidth: ConversationMessageLayout.columnWidth, alignment: alignment)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
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
    let webImageResults: [WebImageResult]
    let sources: [Source]
    let suggestions: [MessageSuggestion]
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
            UserMessageBubble(accent: model.currentAccent) {
                if !message.images.isEmpty { imageGrid }
                if !message.attachments.isEmpty { attachmentChips }
                Text(message.content)
                    .font(.system(size: model.settings.fontSize))
                    .textSelection(.enabled)
                    .foregroundStyle(.primary)
                actions
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
        MessageActionBar {
            Button { model.toggleContextPin(message.id) } label: {
                Image(systemName: model.isContextPinned(message.id) ? "pin.fill" : "pin")
            }
            .help(model.isContextPinned(message.id) ? "Remove from pinned context" : "Pin to context")
            .disabled(pinActionDisabled)
            Button { copyMessage() } label: { Image(systemName: "doc.on.doc") }
            Button { model.branch(fromMessage: message.id) } label: { Image(systemName: "arrow.triangle.branch") }
            Button { model.deleteMessage(message.id) } label: { Image(systemName: "trash") }
        }
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
    @Environment(\.openURL) private var openURL
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
        AssistantMessageLayout(
            assistantName: model.currentAssistantName,
            iconSymbol: model.currentPersona.iconSymbol,
            accent: model.currentAccent,
            surface: model.currentPalette.surfaceRaised,
            border: model.currentPalette.border
        ) {
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

                if !turn.webImageResults.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(turn.webImageResults.enumerated()), id: \.element.id) { index, result in
                            HStack(alignment: .top, spacing: 12) {
                                if let image = ChatView.nsImage(from: result.dataURL) {
                                    Button { zoom = IdentifiableImage(image: image) } label: {
                                        Image(nsImage: image).resizable().scaledToFit()
                                            .frame(width: 220, height: 150)
                                            .background(model.currentPalette.surfaceRaised)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Click to enlarge")
                                }
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(result.title)
                                        .font(.callout.weight(.semibold))
                                        .fixedSize(horizontal: false, vertical: true)
                                    if let url = URL(string: result.sourceURL) {
                                        Link(destination: url) {
                                            Label(
                                                Self.sourceLabel(Source(title: result.title, url: result.sourceURL)),
                                                systemImage: "arrow.up.forward.app")
                                                .font(.caption)
                                                .lineLimit(1)
                                        }
                                        .help(result.sourceURL)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if index < turn.webImageResults.count - 1 {
                                Divider()
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                if isActive, let activity = model.activity {
                    AssistantActivityView(text: activity)
                        .transition(.opacity)
                }

                if turn.interrupted {
                    Label("Interrupted", systemImage: "waveform.badge.minus")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if !turn.suggestions.isEmpty { suggestionsView }
                if !turn.sources.isEmpty { sourcesView }
                actions
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

    private var suggestionsView: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { suggestionButtons }
            VStack(alignment: .leading, spacing: 6) { suggestionButtons }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var suggestionButtons: some View {
        ForEach(turn.suggestions) { suggestion in
            switch suggestion.kind {
            case .reply:
                Button {
                    model.sendSuggestedReply(suggestion.value)
                } label: {
                    Label(suggestion.label, systemImage: "arrowshape.turn.up.left")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!model.canBeginAgentTask && !model.canInterruptWithText && !model.canQueueTextInterrupt)
            case .googleSearch, .webSearch:
                let provider = model.settings.recommendationSearchProvider
                Button {
                    if let url = provider.searchURL(for: suggestion.value) { openURL(url) }
                } label: {
                    Label("Search \(provider.label)", systemImage: "magnifyingglass")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Search \(provider.label) for: \(suggestion.value)")
            }
        }
    }

    private static func sourceLabel(_ src: Source) -> String {
        if let host = URL(string: src.url)?.host {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return src.title.isEmpty ? src.url : src.title
    }

    private var actions: some View {
        MessageActionBar {
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
    @Environment(AppModel.self) private var model
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
        let isReasoningActive = isCurrent && model.isStreaming && content.isEmpty

        VStack(alignment: .leading, spacing: 6) {
            if !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ReasoningDisclosureView(
                    reasoning: reasoning,
                    title: "Reasoning",
                    isGenerating: isReasoningActive
                )
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
    var isGenerating = false
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
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
                if isGenerating && !isExpanded {
                    AssistantActivityView(text: "Thinking…")
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: isGenerating && !isExpanded)
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
        case "web_image_search": return "photo.on.rectangle.angled"
        case "web_search", "web_research": return "magnifyingglass"
        case "web_fetch": return "globe"
        case "calculate": return "function"
        case "python_exec": return "chevron.left.forwardslash.chevron.right"
        case "run_shell": return "terminal"
        case "file_read": return "doc.text"
        case "vault_search", "vault_read", "vault_list", "vault_write", "vault_append": return "lock.doc"
        case "memory_list", "memory_read", "memory_write", "memory_append": return "brain.head.profile"
        case "conversation_search", "conversation_list", "conversation_read": return "clock.arrow.circlepath"
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
        case let .finance(result):
            FinanceArtifactView(result: result)
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

private struct FinanceArtifactView: View {
    let result: FinanceData.Result

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch result.kind {
            case "quote": quoteContent
            case "matches": matchesContent
            case "history", "series": seriesContent
            case "portfolio": portfolioContent
            case "scenario": scenarioContent
            default: Text(result.title).font(.subheadline.weight(.semibold))
            }
            if let note = result.note, !note.isEmpty {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(result.source).lineLimit(1)
                if let asOf = result.asOf { Text("· \(asOf)").lineLimit(1) }
                Spacer(minLength: 0)
                if let url = result.sourceURL.flatMap(URL.init(string:)) {
                    Link(destination: url) {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .help("Open data source")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var quoteContent: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(result.symbol ?? result.title)
                    .font(.caption.weight(.semibold).monospaced())
                if let exchange = result.exchange {
                    Text(exchange).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(amount(result.price, currency: result.currency))
                    .font(.title3.weight(.semibold).monospacedDigit())
                if let change = result.change, let percent = result.changePercent {
                    Text("\(change >= 0 ? "+" : "")\(number(change)) (\(percent >= 0 ? "+" : "")\(number(percent))%)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(change >= 0 ? .green : .red)
                }
                Spacer()
            }
            Text(result.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var matchesContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(result.title).font(.subheadline.weight(.semibold))
            ForEach(result.matches ?? [], id: \.symbol) { match in
                if let url = URL(string: match.url) {
                    Link(destination: url) {
                        HStack(spacing: 6) {
                            Text(match.symbol).font(.caption.monospaced().weight(.semibold))
                            Text(match.name).font(.caption).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(match.exchange).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var seriesContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.title).font(.subheadline.weight(.semibold))
            if let points = result.points, !points.isEmpty {
                Chart(points, id: \.date) { point in
                    LineMark(x: .value("Date", point.date), y: .value("Value", point.value))
                        .foregroundStyle(result.kind == "history" ? Color.green : Color.blue)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 82)
                HStack {
                    Text(points.first?.date ?? "")
                    Spacer()
                    Text("\(number(points.last?.value ?? 0)) \(result.currency ?? "")")
                    Spacer()
                    Text(points.last?.date ?? "")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            } else {
                Text("No observations").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var portfolioContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(result.title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(amount(result.totalValue, currency: result.currency))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
            }
            ForEach(result.positions ?? [], id: \.name) { position in
                HStack(spacing: 8) {
                    Text(position.name).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(number(position.weight * 100))%")
                    Text(amount(position.marketValue, currency: nil))
                        .foregroundStyle(.secondary)
                }
                .font(.caption.monospacedDigit())
            }
            if let concentration = result.concentration {
                Text("Concentration index: \(number(concentration))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var scenarioContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(result.title).font(.subheadline.weight(.semibold))
            valueRow("Total contributions", result.contributionTotal)
            valueRow("Illustrative nominal value", result.projectedNominal)
            valueRow("Inflation-adjusted value", result.projectedReal)
        }
    }

    private func valueRow(_ label: String, _ value: Double?) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(amount(value, currency: result.currency)).monospacedDigit()
        }
        .font(.caption)
    }

    private func amount(_ value: Double?, currency: String?) -> String {
        guard let value else { return "—" }
        let formatted = number(value)
        return currency.map { "\($0) \(formatted)" } ?? formatted
    }

    private func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)))
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
            GeometryReader { geometry in
                let aspectRatio = image.size.width / max(image.size.height, 1)
                let availableWidth = max(1, geometry.size.width - 32)
                let availableHeight = max(1, geometry.size.height - 32)
                let fitWidth = min(availableWidth, availableHeight * aspectRatio)
                let fitHeight = fitWidth / max(aspectRatio, 0.01)

                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: fitWidth * scale, height: fitHeight * scale)
                        .gesture(MagnificationGesture().onChanged { scale = max(0.5, min($0, 6)) })
                        .frame(
                            minWidth: geometry.size.width,
                            minHeight: geometry.size.height,
                            alignment: .center)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 440)
    }
}

