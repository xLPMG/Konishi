import SwiftUI

struct TutorConversationView: View {
    @Environment(AppModel.self) private var appModel
    @Bindable var workspace: LanguageWorkspaceModel
    @State private var confirmDelete = false

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
        .confirmationDialog(
            "Delete this tutor thread?", isPresented: $confirmDelete, titleVisibility: .visible
        ) {
            Button("Delete Thread", role: .destructive) {
                if let id = workspace.selectedTutorThreadID { workspace.deleteTutorThread(id) }
                if workspace.tutorThreads.isEmpty && workspace.activeProfile != nil { workspace.createTutorThread() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes only the selected language tutor thread.")
        }
    }

    private var threadList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tutor threads").font(.headline)
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
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(thread.title).font(.headline).lineLimit(1)
                        Text("\(profile.targetName) · \(profile.baseName)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        appModel.voice.stopSpeaking()
                        confirmDelete = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .help("Delete tutor thread")
                }
                .padding(.horizontal, 16).padding(.vertical, 11)
                Divider()

                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(thread.messages) { message in
                            messageRow(message, profile: profile)
                        }
                        if workspace.isTutorStreaming {
                            HStack(alignment: .top) {
                                Text(workspace.tutorStreamedReply.isEmpty ? "Thinking…" : workspace.tutorStreamedReply)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: 620, alignment: .leading)
                                Spacer(minLength: 40)
                            }
                            .padding(.horizontal, 18).padding(.vertical, 10)
                        }
                    }
                    .padding(.vertical, 18)
                }

                if let error = workspace.tutorError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.top, 8)
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

    private func messageRow(_ message: LanguageTutorMessage, profile: LanguageProfile) -> some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
            HStack(alignment: .top) {
                if message.role == .assistant { Spacer(minLength: 40) }
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(12)
                    .background(
                        message.role == .user ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.09),
                        in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: 620, alignment: message.role == .user ? .trailing : .leading)
                if message.role == .user { Spacer(minLength: 40) }
            }
            if message.role == .assistant {
                HStack(spacing: 12) {
                    Button {
                        appModel.voice.speakBilingual(
                            message.content, targetLocale: profile.targetLocale, baseLocale: profile.baseLocale,
                            targetVoiceID: profile.targetVoiceID, baseVoiceID: profile.baseVoiceID,
                            rate: appModel.settings.speechRate)
                    } label: {
                        Label("Speak", systemImage: "speaker.wave.2")
                    }
                    .buttonStyle(.borderless)
                    .help("Speak this tutor reply")

                    Button {
                        workspace.proposalTopic = "Useful vocabulary and natural synonyms related to: \(String(message.content.prefix(240)))"
                        workspace.destination = .study
                    } label: {
                        Label("Suggest vocabulary", systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Review vocabulary proposals from this tutor reply")
                    Spacer()
                }
                .font(.caption)
                .padding(.leading, 8)
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    private func inputBar(profile: LanguageProfile) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            if appModel.voice.isListening {
                Button {
                    appModel.voice.stopDictation()
                } label: {
                    Image(systemName: "waveform.slash")
                }
                .help("Stop dictation")
            } else {
                Menu {
                    Button(profile.targetName) { startDictation(locale: profile.targetLocale) }
                    Button(profile.baseName) { startDictation(locale: profile.baseLocale) }
                } label: {
                    Image(systemName: "mic")
                }
                .help("Dictate in target or explanation language")
            }

            TextField("Message tutor", text: $workspace.tutorDraft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .onSubmit(send)
                .disabled(workspace.isTutorStreaming)

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
            }
            .buttonStyle(.plain)
            .help("Send message")
            .disabled(workspace.tutorDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workspace.isTutorStreaming)
        }
        .padding(.horizontal, 13).padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18), lineWidth: 1))
        .padding(14)
    }

    private func prepareThreads() {
        workspace.refreshTutorThreads()
        if workspace.tutorThreads.isEmpty && workspace.activeProfile != nil {
            workspace.createTutorThread()
        }
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
        workspace.sendTutorMessage(config: appModel.settings.requestConfig(modelOverride: nil))
    }
}