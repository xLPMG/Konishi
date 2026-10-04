import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Browse the spaced-repetition deck: stats, a filterable card list, and per-card detail
/// (including the display-only register + notes).
struct DeckView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(LanguageWorkspaceModel.self) private var workspace
    @State private var items: [LearnItem] = []
    @State private var stats = LanguageStore.Stats()
    @State private var selection: UUID?
    @State private var search = ""
    @State private var kindFilter: LearnKind?
    @State private var exportItems: [LearnItem] = []
    @State private var showAnkiConfirmation = false
    @State private var showExportAlert = false
    @State private var exportAlertTitle = ""
    @State private var exportAlertMessage = ""
    @State private var cardEditorItem: LearnItem?
    @State private var showCardEditor = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if workspace.activeProfile == nil {
                    ContentUnavailableView("No Language", systemImage: "character.book.closed",
                                           description: Text("Set up a language in Learn mode first."))
                } else if items.isEmpty {
                    ContentUnavailableView("Empty Deck", systemImage: "tray",
                                           description: Text("Cards you learn will appear here."))
                } else {
                    HSplitView {
                        list.frame(minWidth: 240, idealWidth: 280, maxWidth: 360, maxHeight: .infinity)
                        detail.frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(appModel.currentPalette.canvas)
        .onAppear(perform: reload)
        .onChange(of: workspace.deckRevision) { reload() }
        .onChange(of: workspace.activeProfileID) { reload() }
        .onChange(of: kindFilter) { reload() }
        .confirmationDialog(
            "Export \(exportItems.count) vocabulary cards for Anki?",
            isPresented: $showAnkiConfirmation,
            titleVisibility: .visible
        ) {
            Button("Save Text File…", action: saveAnkiExport)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Anki uses Front as its default duplicate-matching field. Review duplicate handling during import.")
        }
        .alert(exportAlertTitle, isPresented: $showExportAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportAlertMessage)
        }
        .sheet(isPresented: $showCardEditor) {
            if let profileID = workspace.activeProfile?.id {
                DeckCardEditor(item: cardEditorItem, profileID: profileID) { item in
                    if kindFilter != nil && kindFilter != item.kind { kindFilter = nil }
                    search = ""
                    selection = item.id
                    reload()
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            statPill("Total", stats.total, .secondary)
            statPill("Due", stats.due, .orange)
            statPill("Mastered", stats.mastered, .green)
            Spacer()
            Button {
                cardEditorItem = nil
                showCardEditor = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .disabled(workspace.activeProfile == nil)
            .help("Add card")
            Picker("Kind", selection: $kindFilter) {
                Text("All").tag(LearnKind?.none)
                ForEach(LearnKind.allCases, id: \.self) { Text($0.label).tag(LearnKind?.some($0)) }
            }
            .pickerStyle(.menu).fixedSize()
            TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 160)
            Button(action: prepareAnkiExport) {
                Label("Export Vocabulary for Anki…", systemImage: "square.and.arrow.up")
            }
            .fixedSize()
            .disabled(workspace.activeProfile == nil)
            .help("Export this profile's vocabulary as an Anki text-import file")
        }
        .padding(12)
    }

    private func statPill(_ label: String, _ value: Int, _ tint: Color) -> some View {
        VStack(spacing: 1) {
            Text("\(value)").font(.title3.weight(.semibold)).foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var filtered: [LearnItem] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter {
            $0.term.lowercased().contains(q) || $0.translation.lowercased().contains(q) || $0.reading.lowercased().contains(q)
        }
    }

    private var list: some View {
        List(filtered, selection: $selection) { item in
            HStack(spacing: 8) {
                Image(systemName: item.kind.icon).foregroundStyle(.secondary).font(.caption)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.term).font(.body.weight(.medium))
                    Text(item.translation).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text("\(item.box)/\(LearnItem.boxCount)")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            .tag(item.id)
            .listRowBackground(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selection == item.id ? appModel.currentPalette.surfaceRaised : appModel.currentPalette.surface)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(appModel.currentPalette.border, lineWidth: 1))
            )
        }
        .scrollContentBackground(.hidden)
        .background(appModel.currentPalette.canvas)
    }

    @ViewBuilder private var detail: some View {
        if let id = selection, let item = items.first(where: { $0.id == id }) {
            CardDetail(
                item: item,
                onSaveAcceptedAnswers: { values in workspace.saveAcceptedAnswers(for: id, values: values) },
                onSaveAcceptedTranslations: { values in workspace.saveAcceptedTranslations(for: id, values: values) },
                onEdit: { cardEditorItem = item; showCardEditor = true },
                onDelete: { workspace.deleteDeckItem(id); selection = nil })
                .id(item.id)
        } else {
            ContentUnavailableView("Select a card", systemImage: "sidebar.left")
        }
    }

    private func reload() {
           guard let pid = workspace.activeProfile?.id else { items = []; stats = .init(); return }
           items = workspace.store.items(profileID: pid, kind: kindFilter)
           stats = workspace.store.stats(profileID: pid)
    }

    private func prepareAnkiExport() {
        guard let profile = workspace.activeProfile else { return }
        exportItems = workspace.store.items(profileID: profile.id, kind: .vocab)
        guard !exportItems.isEmpty else {
            exportAlertTitle = "No vocabulary to export"
            exportAlertMessage = "This profile has no vocabulary cards. No file was created."
            showExportAlert = true
            return
        }
        showAnkiConfirmation = true
    }

    private func saveAnkiExport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = AnkiTextExporter.defaultFilename(
            language: workspace.activeProfile?.targetName ?? "Language")
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try AnkiTextExporter.render(exportItems).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            exportAlertTitle = "Anki export failed"
            exportAlertMessage = error.localizedDescription
            showExportAlert = true
        }
    }
}

private struct DeckCardEditor: View {
    @Environment(AppModel.self) private var appModel
    @Environment(LanguageWorkspaceModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LearnItem
    @State private var saveError: String?
    private let isEditing: Bool
    private let onSave: (LearnItem) -> Void

    init(item: LearnItem?, profileID: UUID, onSave: @escaping (LearnItem) -> Void) {
        self.isEditing = item != nil
        self.onSave = onSave
        _draft = State(initialValue: item ?? LearnItem(
            profileID: profileID, kind: .vocab, term: "", translation: ""))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Card") {
                    Picker("Type", selection: $draft.kind) {
                        ForEach(LearnKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    TextField("Term", text: $draft.term)
                    TextField("Reading or pronunciation", text: $draft.reading)
                    TextField("Translation", text: $draft.translation)
                    TextField("Part of speech", text: $draft.partOfSpeech)
                    TextField("Register", text: $draft.register)
                }

                Section("Usage") {
                    TextField("Examples, one per line", text: examplesText, axis: .vertical)
                        .lineLimit(2...5)
                    TextField("Notes", text: $draft.notes, axis: .vertical)
                        .lineLimit(2...5)
                    TextField("Tags, separated by commas", text: tagsText)
                }

                if draft.kind == .vocab {
                    Section("Accepted answers") {
                        TextField("Target-language forms, one per line", text: acceptedAnswersText, axis: .vertical)
                            .lineLimit(2...5)
                        TextField("Translation alternatives, one per line", text: acceptedTranslationsText, axis: .vertical)
                            .lineLimit(2...5)
                    }
                }

                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            .themedFormBackground(appModel.currentPalette.canvas)
            .navigationTitle(isEditing ? "Edit Card" : "New Card")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let error = workspace.saveDeckItem(draft) else {
                            onSave(draft)
                            dismiss()
                            return
                        }
                        saveError = error
                    }
                    .disabled(draft.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || draft.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(width: 520, height: 650)
    }

    private var examplesText: Binding<String> {
        Binding(
            get: { draft.examples.joined(separator: "\n") },
            set: { draft.examples = lines($0) })
    }

    private var tagsText: Binding<String> {
        Binding(
            get: { draft.tags.joined(separator: ", ") },
            set: { draft.tags = $0.split(separator: ",").map(String.init) })
    }

    private var acceptedAnswersText: Binding<String> {
        Binding(
            get: { draft.acceptedAnswers.joined(separator: "\n") },
            set: { draft.acceptedAnswers = lines($0) })
    }

    private var acceptedTranslationsText: Binding<String> {
        Binding(
            get: { draft.acceptedTranslations.joined(separator: "\n") },
            set: { draft.acceptedTranslations = lines($0) })
    }

    private func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map(String.init)
    }
}

private struct CardDetail: View {
    let item: LearnItem
    let onSaveAcceptedAnswers: ([String]) -> Bool
    let onSaveAcceptedTranslations: ([String]) -> Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var acceptedAnswersText: String
    @State private var acceptedAnswersStatus: String?
    @State private var acceptedTranslationsText: String
    @State private var acceptedTranslationsStatus: String?

    init(
        item: LearnItem, onSaveAcceptedAnswers: @escaping ([String]) -> Bool,
        onSaveAcceptedTranslations: @escaping ([String]) -> Bool, onEdit: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.item = item
        self.onSaveAcceptedAnswers = onSaveAcceptedAnswers
        self.onSaveAcceptedTranslations = onSaveAcceptedTranslations
        self.onEdit = onEdit
        self.onDelete = onDelete
        _acceptedAnswersText = State(initialValue: item.acceptedAnswers.joined(separator: "\n"))
        _acceptedTranslationsText = State(initialValue: item.acceptedTranslations.joined(separator: "\n"))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(item.term).font(.title2.weight(.semibold))
                    if !item.register.isEmpty {
                        Text(item.register).font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(.blue.opacity(0.15)))
                    }
                    Button(action: onEdit) {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("Edit card")
                    Spacer()
                }
                if !item.reading.isEmpty {
                    Text(item.reading).font(.callout).foregroundStyle(.secondary)
                }
                if !item.translation.isEmpty {
                    Text(item.translation).font(.body)
                }
                if !item.partOfSpeech.isEmpty {
                    labelled("Part of speech", item.partOfSpeech)
                }
                if !item.examples.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Examples").font(.caption).foregroundStyle(.secondary)
                        ForEach(item.examples, id: \.self) { Text("• \($0)").font(.callout) }
                    }
                }
                if !item.notes.isEmpty {
                    labelled("Notes", item.notes)
                }
                if !item.tags.isEmpty {
                    labelled("Tags", item.tags.joined(separator: ", "))
                }
                if item.kind == .vocab {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Accepted target-language forms").font(.headline)
                        TextField("Alternate forms, one per line", text: $acceptedAnswersText, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(2...5)
                        HStack {
                            if let acceptedAnswersStatus {
                                Text(acceptedAnswersStatus).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Save answers") {
                                let values = acceptedAnswersText
                                    .split(whereSeparator: \.isNewline)
                                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                                acceptedAnswersStatus = onSaveAcceptedAnswers(values)
                                    ? "Saved"
                                    : "Could not save answers"
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Accepted translation answers").font(.headline)
                        TextField("Alternative translations, one per line", text: $acceptedTranslationsText, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(2...5)
                        HStack {
                            if let acceptedTranslationsStatus {
                                Text(acceptedTranslationsStatus).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Save translations") {
                                let values = acceptedTranslationsText
                                    .split(whereSeparator: \.isNewline)
                                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                                acceptedTranslationsStatus = onSaveAcceptedTranslations(values)
                                    ? "Saved"
                                    : "Could not save translations"
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                Divider()
                HStack(spacing: 20) {
                    stat("Box", "\(item.box)/\(LearnItem.boxCount)")
                    stat("Seen", "\(item.timesSeen)")
                    stat("Correct", "\(item.timesCorrect)")
                    stat("Wrong", "\(item.timesWrong)")
                }
                ProgressView(value: item.mastery)
                    .tint(item.mastery >= 1 ? .green : .accentColor)
                Text("Due \(item.dueDate.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Label("Delete card", systemImage: "trash")
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.clear)
        .onChange(of: item.acceptedAnswers) { _, answers in
            acceptedAnswersText = answers.joined(separator: "\n")
        }
        .onChange(of: item.acceptedTranslations) { _, translations in
            acceptedTranslationsText = translations.joined(separator: "\n")
        }
    }

    private func labelled(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.body.weight(.medium).monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
