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
    private enum Selection: Hashable { case category(MemoryCategory); case other }

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
                case .other: otherDetail
                case nil: ContentUnavailableView("Select a category", systemImage: "tray.full")
                }
            }
            .navigationTitle("Memory")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .frame(minWidth: 640, minHeight: 560)
        .sheet(item: $rawFile) { file in rawEditor(file) }
    }

    // MARK: - Model

    private func file(_ c: MemoryCategory, _ scope: String) -> MemoryStore.File {
        MemoryStore.File(scope: scope, name: c.fileName, url: Paths.memoryScope(scope).appendingPathComponent(c.fileName))
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
        return d
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
        }
    }

    private func tint(_ c: MemoryCategory) -> Color {
        switch c {
        case .profile: .blue
        case .preferences: .purple
        case .projects: .orange
        case .people: .green
        case .history: .pink
        }
    }
}
