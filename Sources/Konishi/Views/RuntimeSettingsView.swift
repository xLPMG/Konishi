import SwiftUI

struct RuntimeSettings: View {
    @Environment(AppModel.self) private var model
    @State private var quickPackage = ""
    @State private var packageFilter = ""

    private var runtime: Runtime { model.runtime }

    var body: some View {
        Form {
            environmentSection
            serversSection
            addSection
            packagesSection
            discoveredSection
            logSection
        }
        .formStyle(.grouped)
        .onAppear {
            if model.discoveredModels.isEmpty { model.scanLocalModels() }
            if runtime.installedPackages.isEmpty { runtime.refreshPackages() }
            runtime.rescan()   // pick up servers started outside Konishi
        }
    }

    private var environmentSection: some View {
        Section("Python Environment") {
            LabeledContent("Python", value: runtime.pythonVersion ?? "not found")
            if !runtime.availableInterpreters.isEmpty {
                Picker("Interpreter", selection: Binding(
                    get: { runtime.interpreter },
                    set: { runtime.interpreter = $0; runtime.detectPython() }
                )) {
                    ForEach(runtime.availableInterpreters, id: \.self) { Text($0).tag($0) }
                }
            }
            LabeledContent("Virtual env") {
                Label(runtime.venvReady ? "Ready" : "Not created",
                      systemImage: runtime.venvReady ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(runtime.venvReady ? .green : .secondary)
            }
            HStack {
                Button(runtime.venvReady ? "Recreate Environment" : "Create Environment") { runtime.createEnv() }
                    .disabled(runtime.busy)
                if runtime.venvReady {
                    Button("Delete", role: .destructive) { runtime.deleteEnv() }
                        .disabled(runtime.busy)
                }
                if runtime.busy { ProgressView().controlSize(.small) }
            }
            HStack {
                TextField("pip install…", text: $quickPackage, prompt: Text("e.g. mlx-audio"))
                Button("Install") {
                    runtime.install(package: quickPackage)
                    quickPackage = ""
                }
                .disabled(runtime.busy || !runtime.venvReady || quickPackage.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Button("Install science libs") { runtime.installScienceLibs() }
                    .disabled(runtime.busy || !runtime.venvReady)
                Text("numpy · scipy · sympy · pandas · matplotlib · arxiv — powers the python_exec tool.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Env lives in ~/Konishi/env. Python 3.12 is recommended — 3.14 lacks wheels for spacy/blis (needed by Kokoro). Recreate/Delete wipes installed packages.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var serversSection: some View {
        Section("Servers") {
            HStack {
                Button("Start All") { model.startAllServers() }
                Button("Stop All") { model.stopAllServers() }
                Spacer()
                Button { runtime.rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .help("Detect servers started outside Konishi and drop dead ones.")
            }
            Toggle("Stop servers when Konishi quits", isOn: Binding(
                get: { model.settings.stopServersOnQuit },
                set: { model.settings.stopServersOnQuit = $0 }
            ))
            if runtime.servers.isEmpty {
                Text("No servers. Add one below.").foregroundStyle(.secondary)
            }
            ForEach(runtime.servers) { server in
                ManagedServerRow(server: server).id(server.id)
            }
        }
    }

    private var addSection: some View {
        Section("Add") {
            ForEach(ManagedServer.presets) { preset in
                Button {
                    runtime.addPreset(preset)
                } label: {
                    Label("Add “\(preset.name)”", systemImage: "plus.circle")
                }
            }
            Button { runtime.addServer() } label: { Label("Add blank server", systemImage: "plus") }
        }
    }

    private var packagesSection: some View {
        Section("Installed Packages (\(runtime.installedPackages.count))") {
            HStack {
                TextField("Filter packages…", text: $packageFilter)
                    .textFieldStyle(.roundedBorder)
                Button("Update All") { runtime.updateAllPackages() }
                    .disabled(!runtime.venvReady || runtime.busy || runtime.installedPackages.isEmpty)
                Button { runtime.refreshPackages() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(!runtime.venvReady || runtime.busy)
            }
            if !runtime.venvReady {
                Text("Create the environment to see installed packages.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(filteredPackages) { pkg in
                            HStack(spacing: 8) {
                                Text(pkg.name).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                                Text(pkg.version).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Update") { runtime.install(package: pkg.name) }
                                    .disabled(runtime.busy)
                                Button(role: .destructive) { runtime.uninstall(pkg.name) } label: {
                                    Image(systemName: "trash")
                                }
                                .disabled(runtime.busy)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 260)   // ~10 rows, scrollable
            }
        }
    }

    private var filteredPackages: [Runtime.PipPackage] {
        let f = packageFilter.trimmingCharacters(in: .whitespaces).lowercased()
        return f.isEmpty ? runtime.installedPackages : runtime.installedPackages.filter { $0.name.lowercased().contains(f) }
    }

    private var discoveredSection: some View {
        Section("Discovered Local Models") {
            HStack {
                Button("Scan") { model.scanLocalModels() }
                Spacer()
                Text("\(model.discoveredModels.count) found").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.discoveredModels.prefix(40)) { entry in
                HStack {
                    Text(entry.name).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.path, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Copy path")
                }
            }
        }
    }

    private var logSection: some View {
        Section("Logs") {
            if runtime.busy {
                Button("Cancel operation", role: .destructive) { runtime.stopOp() }
            }
            ScrollView {
                Text(runtime.log.isEmpty ? "—" : runtime.log)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 160)
            .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

private struct ManagedServerRow: View {
    @Environment(AppModel.self) private var model
    @State private var draft: ManagedServer
    @State private var expanded = false

    init(server: ManagedServer) { _draft = State(initialValue: server) }

    private var runtime: Runtime { model.runtime }
    private var running: Bool { runtime.isRunning(draft.id) }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: $draft.name)
                TextField("pip package", text: $draft.pipPackage)
                TextField("Command", text: $draft.command, axis: .vertical)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1...3)
                TextField("Host", text: $draft.host)
                NumberField("Port", value: $draft.port, range: 1024...65535, step: 1)
                Picker("Role", selection: $draft.role) {
                    ForEach(ManagedServer.Role.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Start on launch", isOn: Binding(
                    get: { draft.autostart ?? false },
                    set: { draft.autostart = $0 }
                ))
                if !draft.note.isEmpty {
                    Text(draft.note).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    let primary = Runtime.primaryPackageName(draft.pipPackage)
                    let version = primary.flatMap { runtime.installedVersion(of: $0) }
                    if let version {
                        Label("v\(version)", systemImage: "checkmark.circle")
                            .font(.caption).foregroundStyle(.green)
                        Button("Update") { runtime.install(package: draft.pipPackage) }
                            .disabled(runtime.busy || !runtime.venvReady || draft.pipPackage.isEmpty)
                    } else {
                        Button("Install") { runtime.install(package: draft.pipPackage) }
                            .disabled(runtime.busy || !runtime.venvReady || draft.pipPackage.isEmpty)
                    }
                    Button(role: .destructive) { runtime.delete(draft.id) } label: { Text("Delete") }
                    Spacer()
                }
            }
            .onChange(of: draft) { runtime.update(draft) }
        } label: {
            HStack(spacing: 10) {
                statusDot
                Text(draft.name).fontWeight(.medium)
                Spacer()
                if running {
                    Button("Stop", role: .destructive) { runtime.stop(draft.id) }
                } else {
                    Button("Start") { model.startServer(draft) }
                        .disabled(draft.command.isEmpty)
                }
                Menu {
                    Button("Use for Chat") { model.useForChat(draft) }
                    Button("Use for Audio") { model.useForAudio(draft) }
                    Button("Use for Embeddings") { model.useForEmbeddings(draft) }
                } label: { Image(systemName: "arrow.right.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private var statusDot: some View {
        let color: Color = switch runtime.status(draft.id) {
        case .running: .green
        case .starting: .yellow
        case .failed: .red
        case .stopped: .secondary
        }
        return Circle().fill(color).frame(width: 8, height: 8)
    }
}
