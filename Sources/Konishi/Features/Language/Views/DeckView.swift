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
    }

    private var header: some View {
        HStack(spacing: 16) {
            statPill("Total", stats.total, .secondary)
            statPill("Due", stats.due, .orange)
            statPill("Mastered", stats.mastered, .green)
            Spacer()
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

private struct CardDetail: View {
    let item: LearnItem
    let onSaveAcceptedAnswers: ([String]) -> Bool
    let onDelete: () -> Void
    @State private var acceptedAnswersText: String
    @State private var acceptedAnswersStatus: String?

    init(item: LearnItem, onSaveAcceptedAnswers: @escaping ([String]) -> Bool, onDelete: @escaping () -> Void) {
        self.item = item
        self.onSaveAcceptedAnswers = onSaveAcceptedAnswers
        self.onDelete = onDelete
        _acceptedAnswersText = State(initialValue: item.acceptedAnswers.joined(separator: "\n"))
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
                        Text("Accepted target-language answers").font(.headline)
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
