import SwiftUI

/// Browse the spaced-repetition deck: stats, a filterable card list, and per-card detail
/// (including the display-only register + notes).
struct DeckView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var items: [LearnItem] = []
    @State private var stats = LanguageStore.Stats()
    @State private var selection: UUID?
    @State private var search = ""
    @State private var kindFilter: LearnKind?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if model.activeLanguageProfile == nil {
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
        .frame(width: 720, height: 520)
        .onAppear(perform: reload)
        .onChange(of: model.languageDeckRevision) { reload() }
        .onChange(of: kindFilter) { reload() }
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
            Button("Done") { dismiss() }
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
        }
    }

    @ViewBuilder private var detail: some View {
        if let id = selection, let item = items.first(where: { $0.id == id }) {
            CardDetail(item: item) { model.deleteDeckItem(id); selection = nil }
        } else {
            ContentUnavailableView("Select a card", systemImage: "sidebar.left")
        }
    }

    private func reload() {
        guard let pid = model.activeLanguageProfile?.id else { items = []; stats = .init(); return }
        items = model.language.items(profileID: pid, kind: kindFilter)
        stats = model.language.stats(profileID: pid)
    }
}

private struct CardDetail: View {
    let item: LearnItem
    let onDelete: () -> Void

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
