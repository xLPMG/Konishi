import SwiftUI

/// Browse and hand-edit the Markdown memory files for global + current persona scopes.
struct MemoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var selection: MemoryStore.File?
    @State private var content = ""
    @State private var newFileName = ""

    private var scopes: [String] {
        [MemoryStore.globalScope, model.currentPersona.memoryScope]
    }

    private var selectionBinding: Binding<MemoryStore.File?> {
        Binding(
            get: { selection },
            set: { file in
                content = file.map { model.memory.read($0) } ?? ""
                selection = file
            }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selectionBinding) {
                ForEach(scopes, id: \.self) { scope in
                    Section {
                        ForEach(model.memory.files(in: scope)) { file in
                            Text(file.name).tag(file)
                        }
                    } header: {
                        let count = model.memory.bulletCount(in: scope)
                        HStack {
                            Text(scope)
                            Spacer()
                            Text("\(count) note\(count == 1 ? "" : "s")")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .safeAreaInset(edge: .bottom) { newFileBar }
        } detail: {
            if let selection {
                editor(for: selection)
            } else {
                ContentUnavailableView("Select a note", systemImage: "doc.text")
            }
        }
        .navigationTitle("Memory")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func editor(for file: MemoryStore.File) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(file.scope)/\(file.name)").font(.headline)
                Spacer()
                Button("Save") {
                    model.memory.write(scope: file.scope, name: file.name, content: content)
                }
                Button(role: .destructive) {
                    model.memory.delete(file)
                    selection = nil
                } label: { Image(systemName: "trash") }
            }
            .padding(10)
            Divider()
            TextEditor(text: $content)
                .font(.system(size: 13, design: .monospaced))
                .padding(6)
        }
    }

    private var newFileBar: some View {
        HStack {
            TextField("new-note.md", text: $newFileName)
                .textFieldStyle(.roundedBorder)
            Button {
                let name = newFileName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                model.memory.write(scope: model.currentPersona.memoryScope, name: name, content: "# \(name)\n")
                newFileName = ""
            } label: { Image(systemName: "plus") }
        }
        .padding(6)
    }
}
