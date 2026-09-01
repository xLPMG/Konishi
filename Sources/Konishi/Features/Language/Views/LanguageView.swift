import SwiftUI

/// Sheet target for the profile editor: nil profile = create new, else edit that profile.
private struct EditorTarget: Identifiable {
    let id = UUID()
    let profile: LanguageProfile?
}

/// The Learn-mode detail pane: a session bar (profile, session kind, topic, deck access) above
/// the reused chat transcript and input.
struct LanguageView: View {
    @Environment(AppModel.self) private var model
    @State private var showDeck = false
    @State private var editorTarget: EditorTarget?
    @State private var profileToDelete: LanguageProfile?
    @State private var due = 0
    @State private var cardCounts: [UUID: Int] = [:]

    var body: some View {
        @Bindable var model = model
        Group {
            if model.activeLanguageProfile == nil {
                setupPrompt
            } else {
                VStack(spacing: 0) {
                    sessionBar(model: model)
                    Divider()
                    ChatView()
                }
            }
        }
        .sheet(isPresented: $showDeck) { DeckView().environment(model) }
        .sheet(item: $editorTarget) { target in
            LanguageProfileEditor(profile: target.profile).environment(model)
        }
        .confirmationDialog(
            profileToDelete.map { "Delete \($0.targetName)?" } ?? "Delete language?",
            isPresented: Binding(get: { profileToDelete != nil }, set: { if !$0 { profileToDelete = nil } }),
            titleVisibility: .visible
        ) {
            if let p = profileToDelete {
                Button("Delete \(p.targetName) and its deck", role: .destructive) {
                    model.deleteLanguageProfile(p.id)
                    profileToDelete = nil
                }
            }
            Button("Cancel", role: .cancel) { profileToDelete = nil }
        } message: {
            Text("This permanently deletes the profile and all its cards.")
        }
        .onAppear(perform: refresh)
        .onChange(of: model.languageDeckRevision) { refresh() }
        .onChange(of: model.settings.activeLanguageProfileID) { refresh() }
        .onChange(of: model.pendingInteraction?.id) { _, id in
            // Free the sheet slot so the multiple-choice prompt can present.
            if id != nil { showDeck = false; editorTarget = nil }
        }
    }

    private var setupPrompt: some View {
        ContentUnavailableView {
            Label("Start Learning", systemImage: "character.book.closed")
        } description: {
            Text("Set up a language to begin. Your vocabulary and grammar are tracked in a spaced-repetition deck.")
        } actions: {
            Button("Set Up a Language") { editorTarget = EditorTarget(profile: nil) }
                .buttonStyle(.borderedProminent)
        }
    }

    private func sessionBar(model: AppModel) -> some View {
        @Bindable var model = model
        return HStack(spacing: 12) {
            profileMenu(model: model)

            Picker("Session", selection: $model.languageSession.kind) {
                ForEach(LanguageSessionKind.allCases) { Label($0.label, systemImage: $0.icon).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            TextField("Topic (optional)", text: $model.languageSession.topic)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)

            if let p = model.activeLanguageProfile {
                Menu {
                    Picker("Mic language", selection: $model.languageInputTarget) {
                        Text(p.targetName).tag(true)
                        Text(p.baseName).tag(false)
                    }
                } label: {
                    Label(model.languageInputTarget ? p.targetName : p.baseName, systemImage: "mic")
                }
                .fixedSize()
                .help("Language the mic listens for when you dictate")
            }

            Spacer()

            if due > 0 {
                Label("\(due) due", systemImage: "clock.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.orange)
            }
            Button { showDeck = true } label: { Label("Deck", systemImage: "rectangle.stack") }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func profileMenu(model: AppModel) -> some View {
        Menu {
            ForEach(model.languageProfiles) { p in
                Button {
                    model.setActiveLanguageProfile(p.id)
                } label: {
                    let label = "\(p.targetName) · \(p.level.code) — \(cardCount(p)) cards"
                    if p.id == model.activeLanguageProfile?.id {
                        Label(label, systemImage: "checkmark")
                    } else {
                        Text(label)
                    }
                }
            }
            Divider()
            Button("New Language…") { editorTarget = EditorTarget(profile: nil) }
            if let active = model.activeLanguageProfile {
                Button("Edit \(active.targetName)…") { editorTarget = EditorTarget(profile: active) }
            }
            if !model.languageProfiles.isEmpty {
                Menu("Delete") {
                    ForEach(model.languageProfiles) { p in
                        Button("\(p.targetName) · \(p.level.code) — \(cardCount(p)) cards", role: .destructive) {
                            profileToDelete = p
                        }
                    }
                }
            }
        } label: {
            if let p = model.activeLanguageProfile {
                Label("\(p.targetName) · \(p.level.code)", systemImage: "character.book.closed")
            } else {
                Label("Language", systemImage: "character.book.closed")
            }
        }
        .fixedSize()
    }

    private func cardCount(_ p: LanguageProfile) -> Int {
        cardCounts[p.id] ?? 0
    }

    private func refresh() {
        due = model.activeLanguageProfile.map { model.languageStore.stats(profileID: $0.id).due } ?? 0
        cardCounts = model.languageStore.cardCounts()
    }
}
