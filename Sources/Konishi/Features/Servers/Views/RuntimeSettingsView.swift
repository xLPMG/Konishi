import SwiftUI
import AppKit

struct RuntimeSettings: View {
    @Environment(AppModel.self) private var model
    @State private var quickPackage = ""
    @State private var packageFilter = ""

    private var runtime: Runtime { model.runtime }

    var body: some View {
        Form {
            serversSection
            builtInServersSection
            customServersSection
            detectedEndpointsSection
            environmentSection
            packagesSection
            logSection
        }
        .formStyle(.grouped)
        .themedFormBackground(model.currentPalette.canvas)
        .onAppear {
            if model.discoveredModels.isEmpty { model.scanLocalModels() }
            model.scanLocalEndpoints()
            if runtime.installedPackages.isEmpty { runtime.refreshPackages() }
            runtime.ensureRoleServers(preferredChatURL: model.settings.baseURL)
            runtime.rescan()   // pick up servers started outside Konishi
        }
    }

    private var environmentSection: some View {
        DisclosureGroup("Python Runtime") {
            VStack(alignment: .leading, spacing: 10) {
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
        }
    }

    private var builtInServersSection: some View {
        Section("Built-in Servers") {
            ForEach(runtime.mlxServers) { server in
                ManagedServerRow(server: server).id(server.id)
            }
        }
    }

    private var customServersSection: some View {
        Section("Custom Servers") {
            if runtime.customServers.isEmpty {
                Text("No custom servers configured.").foregroundStyle(.secondary)
            }
            ForEach(runtime.customServers) { server in
                ManagedServerRow(server: server).id(server.id)
            }
            Button { runtime.addServer() } label: {
                Label("Add Custom Server", systemImage: "plus")
            }
        }
    }

    private var detectedEndpointsSection: some View {
        Section("Other Local Endpoints") {
            HStack {
                Text("Scan common local server ports")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.scanLocalEndpoints() } label: {
                    Label("Scan", systemImage: "arrow.clockwise")
                }
            }
            if model.discoveredEndpoints.isEmpty {
                Text("No compatible endpoints found.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.discoveredEndpoints) { endpoint in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(endpoint.baseURL).font(.system(.body, design: .monospaced))
                        Text(endpoint.modelIDs.isEmpty ? "OpenAI-compatible endpoint" : endpoint.modelIDs.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Menu("Use for…") {
                        ForEach(ManagedServer.Role.primaryRoles) { role in
                            Button(role.label) { model.useDetectedEndpoint(endpoint, for: role) }
                        }
                    }
                }
            }
        }
    }

    private var packagesSection: some View {
        DisclosureGroup("Installed Packages (\(runtime.installedPackages.count))") {
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
    @State private var advanced = false
    @State private var showDeleteConfirmation = false
    @State private var showSplashDraftConfirmation = false
    @State private var splashDraftRepository = ""

    init(server: ManagedServer) { _draft = State(initialValue: server) }

    private var runtime: Runtime { model.runtime }
    private var status: ProcStatus {
        let activeURL = normalized(endpointURL)
        guard activeURL != normalized(draft.endpointURL) else { return runtime.status(draft.id) }
        return model.discoveredEndpoints.contains { normalized($0.baseURL) == activeURL } ? .external : .configured
    }

    private var localStatus: ProcStatus { runtime.status(draft.id) }

    private var managedActive: Bool {
        switch status {
        case .running, .starting, .stopping: true
        default: false
        }
    }

    private var endpointURL: String {
        switch draft.role {
        case .chat: model.settings.baseURL
        case .audio: model.settings.audioBaseURL.isEmpty ? model.settings.baseURL : model.settings.audioBaseURL
        case .embedding: model.settings.embeddingBaseURL.isEmpty ? model.settings.baseURL : model.settings.embeddingBaseURL
        case .none: ""
        }
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: roleIcon).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.role.label).fontWeight(.semibold)
                    Text(endpointURL.isEmpty ? draft.name : "\(draft.name) · \(endpointURL)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                if draft.builtInServer == nil {
                    Button(role: .destructive) { showDeleteConfirmation = true } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete custom server")
                }
                statusLabel
                actionButton
            }
            modelPicker
            if draft.builtInServer?.isChat == true {
                Toggle("Use vision server", isOn: Binding(
                    get: { draft.builtInServer == .mlxVLMChat },
                    set: { enabled in
                        var updated = draft
                        updated.setVisionServer(enabled)
                        draft = updated
                        model.settings.model = updated.modelPath ?? ""
                    }
                ))
                .toggleStyle(.switch)
                .disabled(managedActive)
            }
            if case .failed(let message) = status {
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Toggle("Start on launch", isOn: Binding(
                    get: { draft.autostart },
                    set: { draft.autostart = $0 }
                ))
                .toggleStyle(.switch)
                Spacer()
                if draft.builtInServer == .splash {
                    Text("Splash \(runtime.splashVersion.map { "v\($0)" } ?? "not installed")")
                        .font(.caption.monospaced())
                        .foregroundStyle(runtime.splashVersion == nil ? .secondary : .primary)
                    installButton(installed: runtime.splashVersion != nil, help: "Install or update Splash with Homebrew") {
                        runtime.installSplash()
                    }
                    .disabled(runtime.busy)
                } else {
                    let primary = Runtime.primaryPackageName(draft.pipPackage)
                    let version = primary.flatMap { runtime.installedVersion(of: $0) }
                    if draft.builtInServer != nil {
                        Text("\(primary ?? draft.pipPackage) \(version.map { "v\($0)" } ?? "not installed")")
                            .font(.caption.monospaced())
                            .foregroundStyle(version == nil ? .secondary : .primary)
                    } else if let version {
                        Text("v\(version)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    installButton(installed: version != nil, help: "Install or update this server runtime") {
                        runtime.install(package: draft.pipPackage)
                    }
                    .disabled(runtime.busy || !runtime.venvReady || draft.pipPackage.isEmpty)
                }
            }
            DisclosureGroup("Server options", isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 8) {
                    if draft.builtInServer == nil {
                        TextField("Server name", text: $draft.name)
                            .disabled(managedActive)
                        TextField("Python package", text: $draft.pipPackage)
                            .disabled(managedActive)
                        TextField("Launch command", text: $draft.command, axis: .vertical)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1...3)
                            .disabled(managedActive)
                        Picker("Endpoint role", selection: $draft.role) {
                            ForEach(ManagedServer.Role.allCases, id: \.self) { role in
                                Text(role.label).tag(role)
                            }
                        }
                        .disabled(managedActive)
                    }
                    TextField("Bind address", text: $draft.host)
                        .disabled(managedActive)
                    NumberField("Port", value: $draft.port, range: 1024...65535, step: 1)
                        .disabled(managedActive)
                    if !draft.note.isEmpty {
                        Text(draft.note).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 6)
            }
        }
        .onChange(of: draft) { runtime.update(draft) }
        .confirmationDialog("Delete \(draft.name)?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete Server", role: .destructive) { runtime.delete(draft.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the custom server configuration.")
        }
        .confirmationDialog("Download the required Splash draft?", isPresented: $showSplashDraftConfirmation, titleVisibility: .visible) {
            Button("Download & Start") {
                runtime.downloadSplashDraft(splashDraftRepository, for: draft) {
                    model.startServer(draft)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Konishi will download \(splashDraftRepository), then prepare and start Splash.")
        }
    }

    private var roleIcon: String {
        switch draft.role {
        case .chat: "bubble.left.and.bubble.right"
        case .embedding: "point.3.connected.trianglepath.dotted"
        case .audio: "waveform"
        case .none: "server.rack"
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if runtime.downloadingSplashDrafts.contains(draft.id) {
            Label("Downloading draft", systemImage: "arrow.down.circle").foregroundStyle(.orange)
        } else {
            switch localStatus {
        case .stopped:
            Label("Stopped", systemImage: "circle").foregroundStyle(.secondary)
        case .starting:
            Label("Loading model", systemImage: "arrow.trianglehead.2.clockwise")
                .foregroundStyle(.orange)
        case .running:
            Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .external:
            Label("External", systemImage: "link").foregroundStyle(.blue)
        case .configured:
            Label("Configured", systemImage: "link").foregroundStyle(.secondary)
        case .stopping:
            Label("Stopping", systemImage: "stop.circle").foregroundStyle(.orange)
        case .failed(let message):
            Label("Needs attention", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .help(message)
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if runtime.downloadingSplashDrafts.contains(draft.id) {
            ProgressView().controlSize(.small)
        } else {
            switch localStatus {
        case .running:
            Button("Stop", role: .destructive) { runtime.stop(draft.id) }
        case .starting, .stopping:
            ProgressView().controlSize(.small)
        case .external:
            Button("Use Local") { model.startServer(draft) }
                .help("Use the endpoint already listening on this server's port")
        case .configured:
            Button("Start local") { model.startServer(draft) }
                .disabled(draft.command.isEmpty)
        case .stopped, .failed:
            if let repo = runtime.missingSplashDrafts[draft.id] {
                Button("Download draft…") {
                    splashDraftRepository = repo
                    showSplashDraftConfirmation = true
                }
                .disabled(runtime.busy)
            } else {
                Button(status == .external || status == .configured ? "Start local" : "Start") { model.startServer(draft) }
                    .disabled(draft.command.isEmpty)
            }
            }
        }
    }

    @ViewBuilder
    private var modelPicker: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: 5) {
            if draft.supportsModelSelection {
                pathRow("Model", placeholder: "Local path or Hugging Face ID", text: modelPathBinding) {
                    Menu {
                        ForEach(model.discoveredModels.prefix(100)) { entry in
                            Button(entry.name) { selectModel(entry.path) }
                        }
                    } label: {
                        Image(systemName: "square.grid.2x2")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Choose a detected local model")
                    .disabled(model.discoveredModels.isEmpty)
                    Button(action: chooseModelFolder) {
                        Image(systemName: "folder")
                    }
                    .help("Choose a local model folder")
                }
            }
            if draft.builtInServer == .splash {
                pathRow("Draft", placeholder: "Automatic", text: draftModelBinding) {
                    // Keeps the folder button in the same column as the Model row.
                    Menu {} label: { Image(systemName: "square.grid.2x2") }
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .hidden()
                    Button(action: chooseDraftFolder) {
                        Image(systemName: "folder")
                    }
                    .help("Choose a local DFlash2 draft folder")
                }
            }
            switch draft.role {
            case .audio:
                if model.audioModels.isEmpty {
                    HStack {
                        LabeledContent("Speech models", value: "Not detected")
                        Button("Scan") { model.refreshAudioModels() }
                    }
                } else {
                    Picker("Speech to text", selection: $settings.sttModel) {
                        ForEach(model.sttCandidates) { Text($0.id).tag($0.id) }
                    }
                    Picker("Text to speech", selection: $settings.ttsModel) {
                        ForEach(model.ttsCandidates) { Text($0.id).tag($0.id) }
                    }
                }
            case .chat, .embedding, .none:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func installButton(installed: Bool, help: String, action: @escaping () -> Void) -> some View {
        if installed {
            Button(action: action) {
                Label("Update", systemImage: "arrow.triangle.2.circlepath").labelStyle(.iconOnly)
            }
            .help(help)
        } else {
            Button("Install", action: action).help(help)
        }
    }

    private func pathRow<Actions: View>(
        _ title: String,
        placeholder: String,
        text: Binding<String>,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .frame(width: 52, alignment: .leading)
            TextField(title, text: text, prompt: Text(placeholder))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            actions()
        }
        .disabled(managedActive)
    }

    private var modelPathBinding: Binding<String> {
        Binding(
            get: { draft.modelPath ?? "" },
            set: { selectModel($0) }
        )
    }

    private var draftModelBinding: Binding<String> {
        Binding(
            get: { draft.draftModel ?? "" },
            set: {
                let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                draft.draftModel = value.isEmpty ? nil : value
            }
        )
    }

    private func chooseDraftFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Draft Folder"
        panel.prompt = "Choose Draft"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.draftModel = url.path
    }

    private func shortModelName(_ identifier: String) -> String {
        (identifier.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).lastPathComponent
    }

    private func selectModel(_ path: String) {
        var updated = draft
        updated.setModelPath(path)
        draft = updated
        switch updated.role {
        case .chat: model.settings.model = updated.effectiveAPIModelID ?? path
        case .embedding: model.settings.embeddingModel = path
        case .audio, .none: break
        }
    }

    private func chooseModelFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Model Folder"
        panel.prompt = "Choose Model"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectModel(url.path)
    }
}
