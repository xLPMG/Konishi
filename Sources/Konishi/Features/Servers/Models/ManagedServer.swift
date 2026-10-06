import Foundation

/// A user-managed local server process (LLM or audio), runnable from the venv.
struct ManagedServer: Identifiable, Codable, Equatable, Sendable {
    enum BuiltInServer: String, Codable, Sendable {
        case mlxLMChat
        case mlxVLMChat
        case mlxAudio
        case mlxEmbeddings
        case splash

        var isChat: Bool { self == .mlxLMChat || self == .mlxVLMChat }
    }

    private enum LegacyChatBackend: String, Codable {
        case mlxLM
        case mlxVLM
    }

    enum Role: String, Codable, Sendable, CaseIterable, Identifiable {
        case none, chat, audio, embedding
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none: "Unassigned"
            case .chat: "Chat endpoint"
            case .audio: "Audio endpoint"
            case .embedding: "Embedding endpoint"
            }
        }

        static let primaryRoles: [Role] = [.chat, .embedding, .audio]
    }

    var id = UUID()
    var name: String
    /// pip package(s) to ensure installed (space-separated). May be empty.
    var pipPackage: String
    /// Shell command that starts the server. Runs with the venv on PATH.
    var command: String
    /// Local model path or Hugging Face identifier passed separately to the server command.
    var model: String?
    /// API model identifier when it differs from the local model directory.
    var apiModelID: String?
    var builtInServer: BuiltInServer?
    var isCustom: Bool
    var host: String
    var port: Int
    var role: Role
    /// Short hint shown in the UI.
    var note: String
    /// Start automatically when Konishi launches. Optional for back-compat.
    var autostart: Bool?

    var launchCommand: String {
        if builtInServer == .splash {
            let modelDirectory = modelPath.map(Self.shellQuotePath)
                ?? Self.shellQuotePath("~/.lmstudio/models/incoai/Qwen3.8-27B-Splash")
            let modelID = Self.shellQuote(apiModelID ?? "incoai/Qwen3.8-27B-Splash")
            return "SPLASH_ROOT=\"$(brew --prefix splash)/libexec\"; MODEL_DIR=\(modelDirectory); MODEL_ID=\(modelID); export PYTHONPATH=\"$SPLASH_ROOT\"; exec \"$SPLASH_ROOT/python/bin/python3\" -u -P -m server.server \"$MODEL_DIR\" --tokenizer \"$MODEL_DIR/tokenizer\" --model \"$MODEL_ID\" --binary \"$SPLASH_ROOT/engine/splash\" --port \(port)"
        }
        let stripped = Self.commandWithoutModel(command)
            .replacingOccurrences(of: #"\s*--host(?:=|\s+)\S+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*--port(?:=|\s+)\d+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let modelArgument = modelPath.map { "--model \(Self.shellQuotePath($0))" }
        return ([stripped] + (modelArgument.map { [$0] } ?? []) + ["--host \(Self.shellQuote(host))", "--port \(port)"])
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var supportsModelSelection: Bool {
        let backend = pipPackage.lowercased()
        return role == .chat || role == .embedding || command.contains("--model")
            || backend.contains("mlx-lm") || backend.contains("mlx-vlm") || backend.contains("mlx-embeddings")
    }

    var modelPath: String? {
        if let model { return model }
        let pattern = #"(--model(?:=|\s+))(?:"([^"]*)"|'([^']*)'|(\S+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
                            let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) else { return nil }
                let source = command as NSString
                for group in 2...4 where match.range(at: group).location != NSNotFound {
                        return source.substring(with: match.range(at: group))
        }
        return nil
    }

    mutating func setModelPath(_ path: String) {
        let pattern = #"(--model(?:=|\s+))(?:"([^"]*)"|'([^']*)'|(\S+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let fullRange = NSRange(command.startIndex..., in: command)
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        model = value.isEmpty ? nil : value
        command = regex.stringByReplacingMatches(in: command, range: fullRange, withTemplate: "")
            .trimmingCharacters(in: .whitespaces)
    }

    mutating func setVisionServer(_ enabled: Bool) {
        guard let current = builtInServer, current.isChat else { return }
        configureBuiltInServer(enabled ? .mlxVLMChat : .mlxLMChat)
    }

    mutating func configureBuiltInServer(_ server: BuiltInServer) {
        let previousDefaultModel = builtInServer?.defaultModel
        if model == nil || model?.isEmpty == true || model == previousDefaultModel {
            model = server.defaultModel
        }
        builtInServer = server
        isCustom = false
        name = server.displayName
        pipPackage = server.pipPackage
        command = server.command
        apiModelID = server.apiModelID
        role = server.role
        note = server.note
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func shellQuotePath(_ value: String) -> String {
        if value == "~" { return "\"$HOME\"" }
        if value.hasPrefix("~/") { return "\"$HOME\"/" + shellQuote(String(value.dropFirst(2))) }
        return shellQuote(value)
    }

    private static func extractModelPath(from command: String) -> String? {
        let pattern = #"--model(?:=|\s+)(?:"([^"]*)"|'([^']*)'|(\S+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) else { return nil }
        let source = command as NSString
        for group in 1...3 where match.range(at: group).location != NSNotFound {
            return source.substring(with: match.range(at: group))
        }
        return nil
    }

    private static func commandWithoutModel(_ command: String) -> String {
        let pattern = #"\s*--model(?:=|\s+)(?:"[^"]*"|'[^']*'|\S+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return command }
        return regex.stringByReplacingMatches(
            in: command,
            range: NSRange(command.startIndex..., in: command),
            withTemplate: ""
        ).trimmingCharacters(in: .whitespaces)
    }

    var endpointURL: String {
        let connectHost = ["0.0.0.0", "::", "[::]"].contains(host) ? "127.0.0.1" : host
        var components = URLComponents()
        components.scheme = "http"
        components.host = connectHost
        components.port = port
        return components.url?.absoluteString ?? "http://127.0.0.1:\(port)"
    }

    init(
        id: UUID = UUID(),
        name: String,
        pipPackage: String,
        command: String,
        model: String? = nil,
        apiModelID: String? = nil,
        host: String,
        port: Int,
        role: Role,
        note: String,
        autostart: Bool? = nil,
        builtInServer: BuiltInServer? = nil,
        isCustom: Bool = false
    ) {
        self.id = id
        self.name = name
        self.pipPackage = pipPackage
        self.command = Self.commandWithoutModel(command)
        self.model = model ?? Self.extractModelPath(from: command)
        self.apiModelID = apiModelID
        self.builtInServer = builtInServer
        self.isCustom = isCustom
        self.host = host
        self.port = port
        self.role = role
        self.note = note
        self.autostart = autostart
        if let builtInServer { configureBuiltInServer(builtInServer) }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, pipPackage, command, model, apiModelID, builtInServer, isCustom, host, port, role, note, autostart
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case builtInChatBackend
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let legacyCommand = try values.decode(String.self, forKey: .command)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        pipPackage = try values.decode(String.self, forKey: .pipPackage)
        command = Self.commandWithoutModel(legacyCommand)
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? Self.extractModelPath(from: legacyCommand)
        apiModelID = try values.decodeIfPresent(String.self, forKey: .apiModelID)
        if let persisted = try values.decodeIfPresent(BuiltInServer.self, forKey: .builtInServer) {
            builtInServer = persisted
        } else if let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            .decodeIfPresent(LegacyChatBackend.self, forKey: .builtInChatBackend) {
            builtInServer = legacy == .mlxLM ? .mlxLMChat : .mlxVLMChat
        } else {
            builtInServer = nil
        }
        isCustom = try values.decodeIfPresent(Bool.self, forKey: .isCustom) ?? false
        host = try values.decode(String.self, forKey: .host)
        port = try values.decode(Int.self, forKey: .port)
        role = try values.decode(Role.self, forKey: .role)
        note = try values.decode(String.self, forKey: .note)
        autostart = try values.decodeIfPresent(Bool.self, forKey: .autostart)
    }

    static var presets: [ManagedServer] {
        [
            makeBuiltIn(.mlxLMChat),
            makeBuiltIn(.mlxAudio),
            makeBuiltIn(.mlxEmbeddings),
            makeBuiltIn(.splash)
        ]
    }

    private static func makeBuiltIn(_ kind: BuiltInServer) -> ManagedServer {
        ManagedServer(
            name: kind.displayName,
            pipPackage: kind.pipPackage,
            command: kind.command,
            model: kind.defaultModel,
            host: "127.0.0.1",
            port: kind.port,
            role: kind.role,
            note: kind.note,
            builtInServer: kind
        )
    }
}

private extension ManagedServer.BuiltInServer {
    var displayName: String {
        switch self {
        case .mlxLMChat, .mlxVLMChat: "Chat"
        case .mlxAudio: "Audio"
        case .mlxEmbeddings: "Embeddings"
        case .splash: "Splash"
        }
    }

    var pipPackage: String {
        switch self {
        case .mlxLMChat: "mlx-lm"
        case .mlxVLMChat: "mlx-vlm"
        case .mlxAudio: "mlx-audio[server] misaki[en]"
        case .mlxEmbeddings: "mlx-embeddings"
        case .splash: ""
        }
    }

    var command: String {
        switch self {
        case .mlxLMChat: "mlx_lm.server"
        case .mlxVLMChat: "mlx_vlm.server"
        case .mlxAudio: "mlx_audio.server"
        case .mlxEmbeddings: "python ~/Konishi/python/mlx_embed_server.py"
        case .splash: "splash-server"
        }
    }

    var defaultModel: String? {
        switch self {
        case .mlxLMChat: "~/.lmstudio/models/lmstudio-community/gemma-4-26B-A4B-it-QAT-MLX-4bit"
        case .mlxVLMChat: "mlx-community/gemma-4-12B-it-qat-4bit"
        case .mlxAudio: nil
        case .mlxEmbeddings: "~/.lmstudio/models/AutomatosX/AX-Qwen3-Embedding-0.6B-MLX-AXQ-4bit"
        case .splash: "~/.lmstudio/models/incoai/Qwen3.8-27B-Splash"
        }
    }

    var apiModelID: String? {
        switch self {
        case .splash: "incoai/Qwen3.8-27B-Splash"
        default: nil
        }
    }

    var role: ManagedServer.Role {
        switch self {
        case .mlxLMChat, .mlxVLMChat: .chat
        case .mlxAudio: .audio
        case .mlxEmbeddings: .embedding
        case .splash: .chat
        }
    }

    var port: Int {
        switch self {
        case .mlxLMChat, .mlxVLMChat: 8080
        case .mlxAudio: 8081
        case .mlxEmbeddings: 7997
        case .splash: 8080
        }
    }

    var note: String {
        switch self {
        case .mlxLMChat:
            "Text-only chat server. Use the vision toggle to switch to mlx-vlm."
        case .mlxVLMChat:
            "Vision-capable chat server. The default model downloads from Hugging Face on first start."
        case .mlxAudio:
            "OpenAI-compatible speech and transcription server. Kokoro needs misaki[en]; Python 3.12 is recommended."
        case .mlxEmbeddings:
            "Native MLX embeddings server for semantic memory and document retrieval."
        case .splash:
            "Runs Splash with a local model directory; install/update with the official Homebrew formula."
        }
    }
}

