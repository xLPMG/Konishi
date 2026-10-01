import Foundation
import Observation
import AppKit

enum ProcStatus: Equatable, Sendable {
    case stopped
    case starting
    case running
    case external
    case configured
    case stopping
    case failed(String)
}

/// Manages a local Python virtual environment and user-defined server processes,
/// all controllable from the UI (install mlx-lm / mlx-audio / whisper / piper, run them).
@MainActor
@Observable
final class Runtime {
    var servers: [ManagedServer]
    var log = ""
    /// True while a venv/pip operation is running (one at a time).
    var busy = false
    var pythonVersion: String?
    /// Packages installed in the venv, refreshed after each pip operation.
    var installedPackages: [PipPackage] = []

    struct PipPackage: Identifiable, Sendable, Hashable, Decodable {
        let name: String
        let version: String
        var id: String { name.lowercased() }
    }

    /// A server Konishi launched, remembered by PID so it can be found and stopped after an
    /// app restart or a port edit (the port field alone is not enough — it can change).
    private struct RunningRecord: Codable, Sendable {
        var id: UUID
        var pid: Int32
        var port: Int
        var name: String
        var command: String? = nil
    }

    /// Servers Konishi believes it started (this session or a previous one), keyed by id.
    private var records: [UUID: RunningRecord] = [:]

    private(set) var statuses: [UUID: ProcStatus] = [:]
    private var processes: [UUID: Process] = [:]
    private var opProcess: Process?
    /// Background tasks tailing each server's log file into `log`.
    private var tailTasks: [UUID: Task<Void, Never>] = [:]

    /// The Python used to create the venv (e.g. python3.12). 3.14 lacks wheels for spacy/blis.
    var interpreter: String {
        didSet { UserDefaults.standard.set(interpreter, forKey: "konishi.pythonInterpreter") }
    }
    var availableInterpreters: [String] = []

    private var venvBinPath: String { Paths.venv.appendingPathComponent("bin").path }
    private var pythonBinPath: String { Paths.venv.appendingPathComponent("bin/python").path }

    var roleServers: [ManagedServer] {
        ManagedServer.Role.primaryRoles.compactMap { role in
            servers.first { $0.role == role }
        }
    }

    var venvReady: Bool { FileManager.default.fileExists(atPath: pythonBinPath) }

    init() {
        self.servers = Self.loadServers()
        self.records = Self.loadRecords()
        self.interpreter = UserDefaults.standard.string(forKey: "konishi.pythonInterpreter") ?? Self.bestInterpreter()
        detectPython()
        discoverInterpreters()
        adoptRunning()
        refreshPackages()
        // Kill managed servers when the app quits (unless the user opted out).
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            let stop = (UserDefaults.standard.object(forKey: "konishi.stopServersOnQuit") as? Bool) ?? true
            guard stop else { return }
            MainActor.assumeIsolated { self?.stopAll() }
        }
    }

    /// Recognize servers already listening (orphaned from a previous launch, or started from a
    /// terminal after Konishi launched) so we don't double-start, and drop stale "running" for
    /// ones that have since died. Servers we launched are matched by PID first (survives port
    /// edits); others are matched by their configured port.
    func adoptRunning() {
        for server in servers where processes[server.id] == nil {
            if let rec = records[server.id], Self.recordOwnsServer(rec) {
                statuses[server.id] = .starting  // ours from a prior session (tentative until HTTP-verified)
                startTailing(server.id)
                verifyAdopted(server, port: rec.port)
            } else if Self.portInUse(server.port) {
                records[server.id] = nil         // any stale PID no longer owns this port
                statuses[server.id] = .external  // detected, but not owned by Konishi
                verifyAdopted(server, tailLog: false)
            } else {
                records[server.id] = nil         // gone
                stopTailing(server.id)
                statuses[server.id] = .stopped
            }
        }
        persistRecords()
    }

    /// User-triggered re-scan (Servers list) so servers started outside Konishi become
    /// visible and stoppable, and dead ones stop showing as running.
    func rescan() { adoptRunning() }

    /// A bound port can be a crashed server still holding the socket. Confirm it answers HTTP;
    /// otherwise mark it failed so the UI doesn't claim it's usable. (It stays stoppable — we
    /// still hold its PID/port.)
    private func verifyAdopted(_ server: ManagedServer, port: Int? = nil, tailLog: Bool = true) {
        let port = port ?? server.port
        let id = server.id
        Task { [weak self] in
            let alive = await Self.httpAlive(host: server.host, port: port)
            guard let self, self.processes[id] == nil else { return }
            if alive {
                self.statuses[id] = tailLog ? .running : .external
                if tailLog { self.startTailing(id) }
            } else {
                self.statuses[id] = .failed("not responding")
            }
        }
    }

    /// True when the endpoint responds; auth challenges are reachable, missing routes and server errors are not.
    private static func httpAlive(host: String = "127.0.0.1", port: Int) async -> Bool {
        let connectHost = ["0.0.0.0", "::", "[::]"].contains(host) ? "127.0.0.1" : host
        var components = URLComponents()
        components.scheme = "http"
        components.host = connectHost
        components.port = port
        components.path = "/v1/models"
        guard let url = components.url else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let response = resp as? HTTPURLResponse else { return false }
            return response.statusCode != 404 && response.statusCode < 500
        } catch {
            return false
        }
    }

    func stopAll() {
        let ids = Set(processes.keys).union(records.keys)
        for id in ids { stop(id) }
    }

    func status(_ id: UUID) -> ProcStatus { statuses[id] ?? .stopped }
    func isRunning(_ id: UUID) -> Bool {
        switch status(id) { case .running, .starting, .external, .stopping: true; default: false }
    }

    // MARK: - Environment

    func detectPython() {
        let interp = interpreter
        Task { [weak self] in
            let version = await Self.shellOutput("\(interp) --version")
            self?.pythonVersion = version?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func discoverInterpreters() {
        Task { [weak self] in
            let out = await Self.shellOutput(
                "for v in python3.13 python3.12 python3.11 python3.10 python3; do command -v $v >/dev/null 2>&1 && echo $v; done"
            )
            var seen = Set<String>(); var uniq: [String] = []
            for v in (out ?? "").split(separator: "\n").map(String.init) where seen.insert(v).inserted {
                uniq.append(v)
            }
            self?.availableInterpreters = uniq
        }
    }

    func createEnv() {
        guard !busy else { return }
        let path = Paths.venv.path
        // Recreate from scratch so switching Python versions yields a clean env.
        runOp("Create environment (\(interpreter))",
              command: "rm -rf '\(path)'; \(interpreter) -m venv '\(path)' && '\(path)/bin/python' -m pip install -U pip")
    }

    func deleteEnv() {
        guard !busy else { return }
        stopAll()
        try? FileManager.default.removeItem(at: Paths.venv)
        pythonVersion = nil
        installedPackages = []
        detectPython()
        appendLog("✓ Removed environment at \(Paths.venv.path)\n")
    }

    private static func bestInterpreter() -> String {
        for v in ["python3.12", "python3.11", "python3.13"] where hasCommand(v) { return v }
        return "python3"
    }

    private static func hasCommand(_ name: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v \(name)"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
    }

    private static func portInUse(_ port: Int) -> Bool { !listeningPIDs(port).isEmpty }

    private static func listeningPIDs(_ port: Int) -> [Int32] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        proc.arguments = ["-ti", "tcp:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .compactMap { Int32($0) }
        } catch {
            return []
        }
    }

    /// True if a process with this PID currently exists (no signal sent). EPERM means it exists
    /// but is owned by someone else — still "alive" for our purposes.
    private static func pidAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    private static func killPID(_ pid: Int32) {
        guard pid > 0 else { return }
        kill(pid, SIGKILL)
    }

    private static func terminateServer(pid: Int32, port: Int) async {
        guard listeningPIDs(port).contains(pid) else { return }
        kill(pid, SIGTERM)
        for _ in 0..<20 {
            guard listeningPIDs(port).contains(pid) else { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
        if listeningPIDs(port).contains(pid) { killPID(pid) }
    }

    /// A persisted record is only trustworthy if the PID is alive AND still holds its recorded
    /// port — this guards against a PID that the OS recycled to an unrelated process after a reboot.
    private static func recordOwnsServer(_ rec: RunningRecord) -> Bool {
        pidAlive(rec.pid) && listeningPIDs(rec.port).contains(rec.pid)
    }

    func install(package: String) {
        let pkg = package.trimmingCharacters(in: .whitespaces)
        guard !busy, venvReady, !pkg.isEmpty else { return }
        // `noglob` so package extras like mlx-audio[server] aren't treated as zsh globs.
        runOp("Install \(pkg)", command: "noglob '\(pythonBinPath)' -m pip install -U \(pkg)")
    }

    /// Uninstall a package from the venv.
    func uninstall(_ name: String) {
        let pkg = name.trimmingCharacters(in: .whitespaces)
        guard !busy, venvReady, !pkg.isEmpty else { return }
        runOp("Uninstall \(pkg)", command: "'\(pythonBinPath)' -m pip uninstall -y \(pkg)")
    }

    /// Update every installed package to its latest version.
    func updateAllPackages() {
        guard !busy, venvReady, !installedPackages.isEmpty else { return }
        let names = installedPackages.map(\.name).joined(separator: " ")
        runOp("Update all (\(installedPackages.count))", command: "noglob '\(pythonBinPath)' -m pip install -U \(names)")
    }

    /// Refresh the list of installed packages (venv `pip list`).
    func refreshPackages() {
        guard venvReady else { installedPackages = []; return }
        let py = pythonBinPath
        Task { [weak self] in
            let out = await Self.shellOutput("'\(py)' -m pip list --format=json --disable-pip-version-check 2>/dev/null") ?? ""
            let pkgs = (try? JSONDecoder().decode([PipPackage].self, from: Data(out.utf8))) ?? []
            self?.installedPackages = pkgs.sorted { $0.name.lowercased() < $1.name.lowercased() }
        }
    }

    /// Installed version of a package (canonical name match), or nil if not installed.
    func installedVersion(of package: String) -> String? {
        let key = Self.canonicalName(package)
        return installedPackages.first { Self.canonicalName($0.name) == key }?.version
    }

    private static func canonicalName(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "_", with: "-")
    }

    /// The primary distribution name from a pip spec, e.g. "mlx-audio[server] misaki[en]" -> "mlx-audio".
    static func primaryPackageName(_ pip: String) -> String? {
        guard let first = pip.split(separator: " ").first else { return nil }
        var name = String(first)
        if let bracket = name.firstIndex(of: "[") { name = String(name[..<bracket]) }
        for sep in ["==", ">=", "<=", "~=", ">", "<"] {
            if let r = name.range(of: sep) { name = String(name[..<r.lowerBound]) }
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Install the scientific stack used by the `python_exec` toolkit.
    func installScienceLibs() {
        install(package: SciTools.pipPackages)
    }

    /// Run Python source in the venv (system python3 as fallback) and capture combined
    /// stdout+stderr. Used by the `python_exec` tool. Prepends a bootstrap that makes the
    /// scitools toolkit importable, so agent code can call its functions directly.
    func runPythonCapture(_ code: String, workdir: URL = Paths.root, timeout: Duration = .seconds(90)) async -> (Int32, String) {
        SciTools.ensureInstalled()
        let py = venvReady ? pythonBinPath : "python3"
        // Force a headless backend and auto-save any figures the code leaves open (whether it
        // used the scitools helpers or raw matplotlib) so Konishi can surface them as images.
        let bootstrap = """
        import os as _os
        _os.environ.setdefault("MPLBACKEND", "Agg")
        import sys
        sys.path.insert(0, \(Self.pyQuote(Paths.pythonDir.path)))
        try:
            from scitools import *
            _install_plot_hooks()
        except Exception:
            pass

        """
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("konishi-exec-\(UUID().uuidString).py")
        do {
            try (bootstrap + code).write(to: tmp, atomically: true, encoding: .utf8)
        } catch {
            return (-1, "Could not stage code: \(error.localizedDescription)")
        }
        return await Self.runCapture(python: py, script: tmp.path, workdir: workdir, timeout: timeout, cleanup: tmp)
    }

    /// Run an approved command through the login shell and capture bounded combined output.
    func runShellCapture(
        _ command: String,
        workingDirectory: String?,
        timeoutSeconds: Int
    ) async -> (Int32, String) {
        let directory: URL
        if let workingDirectory, !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            directory = URL(
                fileURLWithPath: (workingDirectory as NSString).expandingTildeInPath,
                isDirectory: true
            )
        } else {
            directory = FileManager.default.homeDirectoryForCurrentUser
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return (-1, "Working directory does not exist: \(directory.path)")
        }
        return await Self.runShellCommand(
            command,
            workdir: directory,
            timeout: .seconds(max(1, min(timeoutSeconds, 600)))
        )
    }

    private static func runShellCommand(
        _ command: String,
        workdir: URL,
        timeout: Duration
    ) async -> (Int32, String) {
        await Task.detached {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = ["-lc", command]
            proc.currentDirectoryURL = workdir
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            do {
                try proc.run()
            } catch {
                return (Int32(-1), "Failed to launch shell: \(error.localizedDescription)")
            }
            let watchdog = Task {
                try? await Task.sleep(for: timeout)
                if proc.isRunning { proc.terminate() }
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            watchdog.cancel()
            let output = String(data: data, encoding: .utf8) ?? ""
            let capped = output.count > 20_000
                ? String(output.prefix(20_000)) + "\n… (output truncated)"
                : output
            return (proc.terminationStatus, capped)
        }.value
    }

    /// A Python string literal for embedding a path in the bootstrap.
    private static func pyQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func runCapture(python: String, script: String, workdir: URL, timeout: Duration, cleanup: URL?) async -> (Int32, String) {
        await Task.detached {
            defer { if let cleanup { try? FileManager.default.removeItem(at: cleanup) } }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = ["-lc", "'\(python)' '\(script)'"]
            proc.currentDirectoryURL = workdir
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            do { try proc.run() } catch { return (Int32(-1), "Failed to launch python: \(error.localizedDescription)") }
            let watchdog = Task {
                try? await Task.sleep(for: timeout)
                if proc.isRunning { proc.terminate() }
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            watchdog.cancel()
            return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        }.value
    }

    func stopOp() {
        opProcess?.terminate()
        opProcess = nil
        busy = false
    }

    // MARK: - Servers

    /// Explicitly (re)launch a server. Frees the port first, so this always yields a fresh
    /// process — used by the manual Start button. For launch-time / Start-All, prefer
    /// `ensureRunning` which adopts an already-healthy instance instead of reloading the model.
    func start(_ server: ManagedServer) async -> Bool {
        guard processes[server.id] == nil else { return false }
        guard !Self.portInUse(server.port) else {
            let message = "Port \(server.port) is already in use; no process was stopped. Choose another port or connect to the existing endpoint."
            statuses[server.id] = .failed(message)
            appendLog("✗ \(server.name): \(message)\n")
            return false
        }
        statuses[server.id] = .starting
        EmbedServer.ensureInstalled()   // materialise the bundled mlx embeddings server script
        let command = server.launchCommand
        let full = "export PATH=\"\(venvBinPath):$PATH\"; exec \(command)"
        appendLog("▶︎ \(server.name): \(command)\n")

        guard let proc = launch(full, id: server.id, isServer: true, logFile: Paths.serverLog(server.id)) else {
            statuses[server.id] = .failed("Could not launch")
            return false
        }
        processes[server.id] = proc
        // `exec` replaces the login shell, so the shell PID is the server's PID.
        records[server.id] = RunningRecord(
            id: server.id, pid: proc.processIdentifier, port: server.port,
            name: server.name, command: server.launchCommand
        )
        persistRecords()
        startTailing(server.id)
        return await waitUntilReady(server, process: proc)
    }

    /// Make sure a server is running WITHOUT creating a duplicate or needlessly reloading the
    /// model: adopt an instance we already own (by PID) or a healthy one on the port, else launch.
    /// Used by autostart and Start-All.
    func ensureRunning(_ server: ManagedServer) async -> Bool {
        if let proc = processes[server.id], proc.isRunning {
            return await waitUntilReady(server, process: proc)
        }
        if let rec = records[server.id], Self.recordOwnsServer(rec) {
            let configurationChanged = rec.port != server.port
                || (rec.command != nil && rec.command != server.launchCommand)
            if configurationChanged {
                await Self.terminateServer(pid: rec.pid, port: rec.port)
                if Self.listeningPIDs(rec.port).contains(rec.pid) {
                    let message = "The previous server is still stopping. Retry Start in a moment."
                    statuses[server.id] = .failed(message)
                    return false
                }
                records[server.id] = nil
                persistRecords()
            } else if await Self.httpAlive(port: rec.port) {
                statuses[server.id] = .running
                startTailing(server.id)
                return true
            } else {
                await Self.terminateServer(pid: rec.pid, port: rec.port)
                records[server.id] = nil
                persistRecords()
            }
        }
        records[server.id] = nil
        if Self.portInUse(server.port) {
            if await Self.httpAlive(host: server.host, port: server.port) {
                statuses[server.id] = .external
                return true
            }
            let message = "Port \(server.port) is occupied, but the endpoint is not responding. No process was stopped."
            statuses[server.id] = .failed(message)
            appendLog("✗ \(server.name): \(message)\n")
            return false
        }
        return await start(server)
    }

    private func waitUntilReady(_ server: ManagedServer, process: Process) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(300))
        while ContinuousClock.now < deadline {
            guard processes[server.id] === process, process.isRunning, status(server.id) != .stopping else { return false }
            if await Self.httpAlive(host: server.host, port: server.port) {
                guard processes[server.id] === process else { return false }
                statuses[server.id] = .running
                appendLog("✓ \(server.name) is ready at http://127.0.0.1:\(server.port)\n")
                return true
            }
            try? await Task.sleep(for: .seconds(1))
        }
        guard processes[server.id] === process, process.isRunning else { return false }
        let message = "The server has not responded after 5 minutes. It is still running; check the log, retry Start, or Stop it."
        statuses[server.id] = .failed(message)
        appendLog("✗ \(server.name): \(message)\n")
        return false
    }

    func stop(_ id: UUID) {
        stopTailing(id)
        if let proc = processes[id] {
            statuses[id] = .stopping
            proc.terminate()
            let pid = proc.processIdentifier
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.processes[id] === proc, proc.isRunning else { return }
                kill(pid, SIGKILL)
            }
        } else if let rec = records[id], Self.recordOwnsServer(rec) {
            statuses[id] = .stopping
            Task { [weak self] in
                await Self.terminateServer(pid: rec.pid, port: rec.port)
                guard let self, self.records[id]?.pid == rec.pid else { return }
                self.records[id] = nil
                self.persistRecords()
                self.statuses[id] = .stopped
            }
            return
        } else if case .external = status(id) {
            return
        } else {
            records[id] = nil
        }
        persistRecords()
        if processes[id] == nil { statuses[id] = .stopped }
    }

    // MARK: - Server log tailing (servers write to a file, not a pipe that dies with Konishi)

    private func startTailing(_ id: UUID) {
        stopTailing(id)
        let url = Paths.serverLog(id)
        tailTasks[id] = Task { [weak self] in
            var offset: UInt64 = 0
            while !Task.isCancelled {
                if let handle = try? FileHandle(forReadingFrom: url) {
                    try? handle.seek(toOffset: offset)
                    let data = handle.readDataToEndOfFile()
                    try? handle.close()
                    if !data.isEmpty {
                        offset += UInt64(data.count)
                        if let text = String(data: data, encoding: .utf8) { self?.appendLog(text) }
                    }
                }
                try? await Task.sleep(for: .milliseconds(800))
            }
        }
    }

    private func stopTailing(_ id: UUID) {
        tailTasks[id]?.cancel()
        tailTasks[id] = nil
    }

    func addServer() {
        servers.append(ManagedServer(name: "New Server", pipPackage: "", command: "", host: "127.0.0.1", port: 8090, role: .none, note: ""))
        saveServers()
    }

    func ensureRoleServers() {
        for role in ManagedServer.Role.primaryRoles where !servers.contains(where: { $0.role == role }) {
            guard let preset = ManagedServer.presets.first(where: { $0.role == role }) else { continue }
            var server = preset
            server.id = UUID()
            servers.append(server)
        }
        saveServers()
    }

    func addPreset(_ preset: ManagedServer) {
        var copy = preset
        copy.id = UUID()
        servers.append(copy)
        saveServers()
    }

    func update(_ server: ManagedServer) {
        guard let idx = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[idx] = server
        saveServers()
    }

    func delete(_ id: UUID) {
        stop(id)
        servers.removeAll { $0.id == id }
        saveServers()
    }

    // MARK: - Process plumbing

    private func runOp(_ label: String, command: String) {
        guard !busy else { return }
        busy = true
        appendLog("\n$ \(label)\n")
        guard let proc = launch(command, id: nil, isServer: false) else {
            busy = false
            return
        }
        opProcess = proc
    }

    private func launch(_ command: String, id: UUID?, isServer: Bool, logFile: URL? = nil) -> Process? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", command]
        // Run from a writable dir; some servers create relative folders like logs/.
        proc.currentDirectoryURL = Paths.root

        if let logFile {
            // Servers log to a file (an inherited FD that outlives Konishi) so they don't hang
            // on a broken pipe when the app quits. Konishi tails the file for live output.
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
            if let fh = try? FileHandle(forWritingTo: logFile) {
                proc.standardOutput = fh
                proc.standardError = fh
            }
        } else {
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in self?.appendLog(text) }
            }
        }
        proc.terminationHandler = { [weak self] p in
            let code = p.terminationStatus
            Task { @MainActor in self?.handleTermination(id: id, isServer: isServer, code: code) }
        }
        do {
            try proc.run()
            return proc
        } catch {
            appendLog("Failed to launch: \(error.localizedDescription)\n")
            return nil
        }
    }

    private func handleTermination(id: UUID?, isServer: Bool, code: Int32) {
        if isServer, let id {
            stopTailing(id)
            processes[id] = nil
            records[id] = nil
            persistRecords()
            let name = servers.first(where: { $0.id == id })?.name ?? "Server"
            switch statuses[id] {
            case .running, .starting:
                statuses[id] = code == 0 ? .stopped : .failed("Exited (code \(code))")
            case .failed(let message):
                statuses[id] = .failed(message)
            default:
                statuses[id] = .stopped
            }
            if code != 0 { appendLog("✗ \(name) exited with code \(code). Check its server log above.\n") }
        } else {
            opProcess = nil
            busy = false
            appendLog(code == 0 ? "✓ done\n" : "✗ exited with code \(code)\n")
            detectPython()
            refreshPackages()
        }
    }

    private func appendLog(_ text: String) {
        log += text
        if log.count > 40_000 { log = String(log.suffix(32_000)) }
    }

    private static func shellOutput(_ command: String) async -> String? {
        await withCheckedContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = ["-lc", command]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            proc.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8))
            }
            do { try proc.run() } catch { continuation.resume(returning: nil) }
        }
    }

    // MARK: - Persistence

    private func saveServers() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        try? data.write(to: Paths.serversFile, options: .atomic)
    }

    private static func loadServers() -> [ManagedServer] {
        guard let data = try? Data(contentsOf: Paths.serversFile),
              let decoded = try? JSONDecoder().decode([ManagedServer].self, from: data),
              !decoded.isEmpty
        else { return ManagedServer.presets }
        return decoded
    }

    private func persistRecords() {
        guard let data = try? JSONEncoder().encode(Array(records.values)) else { return }
        try? data.write(to: Paths.runningServersFile, options: .atomic)
    }

    private static func loadRecords() -> [UUID: RunningRecord] {
        guard let data = try? Data(contentsOf: Paths.runningServersFile),
              let decoded = try? JSONDecoder().decode([RunningRecord].self, from: data)
        else { return [:] }
        return Dictionary(decoded.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }
}
