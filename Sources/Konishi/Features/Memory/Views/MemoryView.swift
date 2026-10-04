import SwiftUI

/// Structured viewer/editor for the categorized bullet-point memory (global + current persona).
/// Presents each category as a card with per-bullet editing, live search, and a schema check.
struct MemoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var search = ""
    @State private var version = 0                       // bump to reload after a write
    @State private var draft: [MemoryCategory: String] = [:]
    @State private var editing: BulletID?
    @State private var editingText = ""
    @State private var hovered: BulletID?
    @State private var rawFile: MemoryStore.File?
    @State private var rawText = ""
    @State private var newNote = ""

    private struct BulletID: Hashable { let category: MemoryCategory; let index: Int }
    private enum Selection: Hashable { case category(MemoryCategory); case recent; case summaries; case other }

    @State private var selection: Selection? = .category(.profile)

    private var globalScope: String { MemoryStore.globalScope }
    private var personaScope: String { model.currentPersona.memoryScope }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            Group {
                switch selection {
                case .category(let c): categoryDetail(c)
                case .recent: recentDetail
                case .summaries: summariesDetail
                case .other: otherDetail
                case nil: ContentUnavailableView("Select a category", systemImage: "tray.full")
                }
            }
            .navigationTitle("Memory")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .background(model.currentPalette.canvas)
        }
        .background(model.currentPalette.canvas.ignoresSafeArea())
        .frame(minWidth: 640, minHeight: 560)
        .sheet(item: $rawFile) { file in rawEditor(file) }
    }

    // MARK: - Model

    private func file(_ c: MemoryCategory, _ scope: String) -> MemoryStore.File {
        model.memoryStore.file(scope: scope, name: c.fileName)
    }

    private func scope(_ c: MemoryCategory) -> String {
        c.targetScope(global: globalScope, persona: personaScope)
    }

    private var extraFiles: [MemoryStore.File] {
        _ = version
        let categoryNames = Set(MemoryCategory.allCases.map(\.fileName))
        return [globalScope, personaScope].flatMap { scope in
            model.memoryStore.files(in: scope).filter { !categoryNames.contains($0.name) }
        }
    }

    /// Note counts per sidebar entry. Reads `version` so the sidebar refreshes after any edit.
    private var counts: [Selection: Int] {
        _ = version
        var d: [Selection: Int] = [:]
        for c in MemoryCategory.allCases { d[.category(c)] = fullBullets(c, scope(c)).count }
        d[.other] = extraFiles.count
        d[.recent] = recentFacts.count
        d[.summaries] = summarizedConversations.count
        return d
    }

    /// Short-term facts for the global scope and the current persona, newest first.
    private var recentFacts: [STMFact] {
        _ = version
        let scopes = [globalScope, personaScope]
        return model.stm.facts.filter { scopes.contains($0.scope) }.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        let counts = counts
        return List(selection: $selection) {
            Section("Categories") {
                ForEach(MemoryCategory.allCases, id: \.self) { c in
                    Label {
                        HStack {
                            Text(c.header)
                            Spacer()
                            Text("\(counts[.category(c)] ?? 0)")
                                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: icon(c)).foregroundStyle(tint(c))
                    }
                    .tag(Selection.category(c))
                }
            }
            Section {
                Label {
                    HStack {
                        Text("Recent")
                        Spacer()
                        Text("\(counts[.recent] ?? 0)")
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "hourglass").foregroundStyle(.teal)
                }
                .tag(Selection.recent)
                Label {
                    HStack {
                        Text("Conversations")
                        Spacer()
                        Text("\(counts[.summaries] ?? 0)")
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "text.bubble").foregroundStyle(.indigo)
                }
                .tag(Selection.summaries)
                Label {
                    HStack {
                        Text("Other notes")
                        Spacer()
                        Text("\(counts[.other] ?? 0)")
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                }
                .tag(Selection.other)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(model.currentPalette.sidebar)
    }

    // MARK: - Category detail

    private func categoryDetail(_ c: MemoryCategory) -> some View {
        let scope = scope(c)
        let bullets = fullBullets(c, scope)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icon(c)).foregroundStyle(tint(c)).font(.title)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(c.header).font(.title2.weight(.semibold))
                        scopeBadge(scope)
                    }
                    Text(c.guidance).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    let visible = Array(bullets.enumerated()).filter { matches($0.element) }
                    if visible.isEmpty {
                        Text(search.isEmpty ? "No notes yet." : "No matches.")
                            .foregroundStyle(.tertiary).padding(.vertical, 12)
                    }
                    ForEach(visible, id: \.offset) { index, bullet in
                        bulletRow(c, scope, index, bullet)
                    }
                }
                .padding(16)
            }
            .searchable(text: $search, placement: .toolbar, prompt: "Search \(c.header.lowercased())")
            Divider()
            addRow(c, scope).padding(16)
        }
    }

    private func bulletRow(_ c: MemoryCategory, _ scope: String, _ index: Int, _ bullet: String) -> some View {
        let id = BulletID(category: c, index: index)
        return HStack(alignment: .top, spacing: 8) {
            Circle().fill(tint(c).opacity(0.55)).frame(width: 5, height: 5).padding(.top, 7)
            if editing == id {
                TextField("Edit note", text: $editingText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitEdit(c, scope, index) }
                Button("Save") { commitEdit(c, scope, index) }.buttonStyle(.borderless)
                Button("Cancel") { editing = nil }.buttonStyle(.borderless).foregroundStyle(.secondary)
            } else {
                Text(bullet)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if hovered == id {
                    Button { editing = id; editingText = bullet } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless).help("Edit")
                    Button(role: .destructive) { deleteBullet(c, scope, index) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Delete")
                }
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(hovered == id ? AnyShapeStyle(tint(c).opacity(0.06)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { inside in hovered = inside ? id : (hovered == id ? nil : hovered) }
    }

    private func addRow(_ c: MemoryCategory, _ scope: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill").foregroundStyle(tint(c).opacity(0.5))
            TextField("Add a note…", text: Binding(get: { draft[c] ?? "" }, set: { draft[c] = $0 }))
                .textFieldStyle(.plain)
                .onSubmit { addBullet(c, scope) }
        }
        .padding(.top, 2)
    }

    private func scopeBadge(_ scope: String) -> some View {
        Text(scope == globalScope ? "Global" : "Persona")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(.secondary.opacity(0.15)))
            .foregroundStyle(.secondary)
    }

    // MARK: - Conversation summaries (read-only)

    private var summarizedConversations: [Conversation] {
        model.conversations
            .filter { !($0.digest ?? "").isEmpty }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var summariesDetail: some View {
        let all = summarizedConversations
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = query.isEmpty
            ? all : all.filter { $0.title.lowercased().contains(query) || ($0.digest ?? "").lowercased().contains(query) }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "text.bubble").foregroundStyle(.indigo).font(.title)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Conversations").font(.title2.weight(.semibold))
                    Text("A short summary of each chat, kept up to date automatically. The assistant recalls these in later chats.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if shown.isEmpty {
                        Text(search.isEmpty ? "No summaries yet." : "No matches.")
                            .foregroundStyle(.tertiary).padding(.vertical, 12)
                    }
                    ForEach(shown) { convo in summaryRow(convo) }
                }
                .padding(16)
            }
            .searchable(text: $search, placement: .toolbar, prompt: "Search summaries")
        }
    }

    private func summaryRow(_ convo: Conversation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(convo.title).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer()
                Text(ConversationRecall.dateString(convo.updatedAt))
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open") {
                    model.selectedConversationID = convo.id
                    dismiss()
                }
                .buttonStyle(.borderless).font(.caption)
            }
            Text(convo.digest ?? "").font(.callout).textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
    }

    // MARK: - Recent (short-term) facts

    private var recentDetail: some View {
        let facts = recentFacts
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "hourglass").foregroundStyle(.teal).font(.title)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recent").font(.title2.weight(.semibold))
                    Text("Newly learned facts. They are already used in chats; the ones that prove important are moved to long-term memory automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if facts.isEmpty {
                        Text("Nothing pending.").foregroundStyle(.tertiary).padding(.vertical, 12)
                    }
                    ForEach(facts) { fact in recentRow(fact) }
                }
                .padding(16)
            }
        }
    }

    private func recentRow(_ fact: STMFact) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(fact.text).font(.callout).textSelection(.enabled)
                Text("\(fact.category.header) · importance \(fact.salience)/3 · used in \(fact.retrievals) chat\(fact.retrievals == 1 ? "" : "s") · \(max(0, model.stm.activeDay - fact.createdDay)) active days old")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.stm.promote(fact.id, to: model.memoryStore)
                version += 1
            } label: { Image(systemName: "arrow.up.doc") }
                .buttonStyle(.borderless).help("Move to long-term memory now")
            Button(role: .destructive) {
                model.stm.remove(fact.id)
                version += 1
            } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Forget")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
    }

    // MARK: - Other (non-category) notes

    private var otherDetail: some View {
        let files = extraFiles
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text").foregroundStyle(.secondary).font(.title)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Other notes").font(.title2.weight(.semibold))
                    Text("Free-form notes you or the assistant create.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if files.isEmpty {
                        Text("No free-form notes.").foregroundStyle(.tertiary).padding(.vertical, 12)
                    }
                    ForEach(files, id: \.id) { f in
                        HStack {
                            Image(systemName: "doc").foregroundStyle(.secondary)
                            Text("\(f.scope)/\(f.name)")
                            Spacer()
                            Button { rawText = model.memoryStore.read(f); rawFile = f } label: { Image(systemName: "square.and.pencil") }
                                .buttonStyle(.borderless).help("Edit")
                            Button(role: .destructive) { model.memoryStore.delete(f); version += 1 } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).help("Delete")
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
                    }
                }
                .padding(16)
            }
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill").foregroundStyle(.secondary)
                TextField("new-note.md", text: $newNote).textFieldStyle(.plain).onSubmit(addNote)
            }
            .padding(16)
        }
    }

    private func rawEditor(_ file: MemoryStore.File) -> some View {
        NavigationStack {
            TextEditor(text: $rawText)
                .font(.system(size: 13, design: .monospaced))
                .padding(8)
                .navigationTitle("\(file.scope)/\(file.name)")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { rawFile = nil } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            model.memoryStore.write(scope: file.scope, name: file.name, content: rawText)
                            version += 1
                            rawFile = nil
                        }
                    }
                }
        }
        .frame(minWidth: 460, minHeight: 380)
    }

    // MARK: - Mutations (all go through the schema canonicalizer)

    private func fullBullets(_ c: MemoryCategory, _ scope: String) -> [String] {
        MemoryStore.blocks(model.memoryStore.read(file(c, scope))).map(Self.strip)
    }

    private func save(_ c: MemoryCategory, _ scope: String, _ bullets: [String]) {
        let clean = MemoryProfile.canonical(bullets.map { "- \($0)" }.joined(separator: "\n"))
        if clean.isEmpty {
            model.memoryStore.delete(scope: scope, name: c.fileName)
        } else {
            model.memoryStore.write(scope: scope, name: c.fileName, content: clean)
        }
        version += 1
    }

    private func addBullet(_ c: MemoryCategory, _ scope: String) {
        let text = (draft[c] ?? "").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        save(c, scope, fullBullets(c, scope) + [text])
        draft[c] = ""
    }

    private func deleteBullet(_ c: MemoryCategory, _ scope: String, _ index: Int) {
        var b = fullBullets(c, scope)
        guard b.indices.contains(index) else { return }
        b.remove(at: index)
        save(c, scope, b)
    }

    private func commitEdit(_ c: MemoryCategory, _ scope: String, _ index: Int) {
        let text = editingText.trimmingCharacters(in: .whitespaces)
        var b = fullBullets(c, scope)
        guard b.indices.contains(index) else { editing = nil; return }
        if text.isEmpty { b.remove(at: index) } else { b[index] = text }
        editing = nil
        save(c, scope, b)
    }

    private func addNote() {
        let name = newNote.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let fileName = name.hasSuffix(".md") ? name : name + ".md"
        model.memoryStore.write(scope: personaScope, name: fileName, content: "- ")
        newNote = ""
        version += 1
    }

    // MARK: - Helpers

    private func matches(_ s: String) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || s.lowercased().contains(q)
    }

    private static func strip(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        while t.hasPrefix("-") || t.hasPrefix("*") {
            t.removeFirst()
            t = t.trimmingCharacters(in: .whitespaces)
        }
        return t
    }

    private func icon(_ c: MemoryCategory) -> String {
        switch c {
        case .profile: "person.text.rectangle"
        case .preferences: "slider.horizontal.3"
        case .projects: "hammer"
        case .people: "person.2"
        case .history: "clock"
        case .rapport: "bubble.left.and.bubble.right"
        }
    }

    private func tint(_ c: MemoryCategory) -> Color {
        switch c {
        case .profile: .blue
        case .preferences: .purple
        case .projects: .orange
        case .people: .green
        case .history: .pink
        case .rapport: .teal
        }
    }
}
