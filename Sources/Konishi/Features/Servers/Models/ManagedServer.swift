import Foundation

/// A user-managed local server process (LLM or audio), runnable from the venv.
struct ManagedServer: Identifiable, Codable, Equatable, Sendable {
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
    var host: String
    var port: Int
    var role: Role
    /// Short hint shown in the UI.
    var note: String
    /// Start automatically when Konishi launches. Optional for back-compat.
    var autostart: Bool?

    var launchCommand: String {
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
        host: String,
        port: Int,
        role: Role,
        note: String,
        autostart: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.pipPackage = pipPackage
        self.command = Self.commandWithoutModel(command)
        self.model = model ?? Self.extractModelPath(from: command)
        self.host = host
        self.port = port
        self.role = role
        self.note = note
        self.autostart = autostart
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, pipPackage, command, model, host, port, role, note, autostart
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let legacyCommand = try values.decode(String.self, forKey: .command)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        pipPackage = try values.decode(String.self, forKey: .pipPackage)
        command = Self.commandWithoutModel(legacyCommand)
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? Self.extractModelPath(from: legacyCommand)
        host = try values.decode(String.self, forKey: .host)
        port = try values.decode(Int.self, forKey: .port)
        role = try values.decode(Role.self, forKey: .role)
        note = try values.decode(String.self, forKey: .note)
        autostart = try values.decodeIfPresent(Bool.self, forKey: .autostart)
    }

    static var presets: [ManagedServer] {
        [
            ManagedServer(
                name: "mlx-lm (chat)",
                pipPackage: "mlx-lm",
                command: "mlx_lm.server",
                model: "~/.lmstudio/models/lmstudio-community/gemma-4-26B-A4B-it-QAT-MLX-4bit",
                host: "127.0.0.1",
                port: 8080,
                role: .chat,
                note: "Local path = no download. An HF repo id (e.g. mlx-community/…) would download to ~/.cache/huggingface/hub. Text-only — for image input use the mlx-vlm preset instead."
            ),
            ManagedServer(
                name: "mlx-vlm (vision chat)",
                pipPackage: "mlx-vlm",
                command: "mlx_vlm.server",
                model: "~/.lmstudio/models/lmstudio-community/gemma-4-26B-A4B-it-QAT-MLX-4bit",
                host: "127.0.0.1",
                port: 8080,
                role: .chat,
                note: "Vision-capable OpenAI server: accepts image inputs (unlike mlx_lm.server). Then enable 'Send images to the model' in Settings › Generation. Uses port 8080 — stop the mlx-lm server first."
            ),
            ManagedServer(
                name: "mlx-audio (TTS + STT)",
                pipPackage: "mlx-audio[server] misaki[en]",
                command: "mlx_audio.server",
                host: "127.0.0.1",
                port: 8081,
                role: .audio,
                note: "OpenAI-compatible /v1/audio/speech + /v1/audio/transcriptions. Kokoro needs misaki[en] (pulls spacy — use a Python 3.12 env, not 3.14). Pick the model per request in the Voice tab (e.g. TTS mlx-community/Kokoro-82M-bf16). Models download to ~/.cache/huggingface/hub on first use."
            ),
            ManagedServer(
                name: "mlx embeddings",
                pipPackage: "mlx-embeddings",
                command: "python ~/Konishi/python/mlx_embed_server.py",
                model: "~/.lmstudio/models/AutomatosX/AX-Qwen3-Embedding-0.6B-MLX-AXQ-4bit",
                host: "127.0.0.1",
                port: 7997,
                role: .embedding,
                note: "Native MLX embeddings server (no torch) exposing /v1/embeddings, so RAG/semantic memory runs on Apple Silicon while mlx serves chat. Konishi ships the server script; just install mlx-embeddings, point --model at a local mlx embedding model, Start, then 'Use for Embeddings'. Set the same id as your Embedding model in Settings."
            )
        ]
    }
}
