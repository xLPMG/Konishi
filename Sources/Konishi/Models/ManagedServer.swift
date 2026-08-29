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
    }

    var id = UUID()
    var name: String
    /// pip package(s) to ensure installed (space-separated). May be empty.
    var pipPackage: String
    /// Shell command that starts the server. Runs with the venv on PATH.
    var command: String
    var port: Int
    var role: Role
    /// Short hint shown in the UI.
    var note: String
    /// Start automatically when Konishi launches. Optional for back-compat.
    var autostart: Bool?

    /// The port every lifecycle op uses. The `port` field is the single source of truth: the
    /// launched command's `--port` is normalized to it, so the UI field always wins and the two
    /// can't drift. Use this, never `port` directly, so intent stays centralized.
    var effectivePort: Int { port }

    /// The command actually launched: strips any `--port` the free-text command carries and
    /// appends the UI's port, so you never specify the port twice and editing the field always
    /// takes effect. (Assumes a `--port` flag — the mlx / OpenAI-style servers Konishi runs all use it.)
    var launchCommand: String {
        let stripped = command
            .replacingOccurrences(of: #"\s*--port(?:=|\s+)\d+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return stripped + " --port \(port)"
    }

    init(
        id: UUID = UUID(),
        name: String,
        pipPackage: String,
        command: String,
        port: Int,
        role: Role,
        note: String,
        autostart: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.pipPackage = pipPackage
        self.command = command
        self.port = port
        self.role = role
        self.note = note
        self.autostart = autostart
    }

    static var presets: [ManagedServer] {
        [
            ManagedServer(
                name: "mlx-lm (chat)",
                pipPackage: "mlx-lm",
                command: "mlx_lm.server --model ~/.lmstudio/models/lmstudio-community/gemma-4-26B-A4B-it-QAT-MLX-4bit",
                port: 8080,
                role: .chat,
                note: "Local path = no download. An HF repo id (e.g. mlx-community/…) would download to ~/.cache/huggingface/hub. Text-only — for image input use the mlx-vlm preset instead."
            ),
            ManagedServer(
                name: "mlx-vlm (vision chat)",
                pipPackage: "mlx-vlm",
                command: "mlx_vlm.server --model ~/.lmstudio/models/lmstudio-community/gemma-4-26B-A4B-it-QAT-MLX-4bit",
                port: 8080,
                role: .chat,
                note: "Vision-capable OpenAI server: accepts image inputs (unlike mlx_lm.server). Then enable 'Send images to the model' in Settings › Generation. Uses port 8080 — stop the mlx-lm server first."
            ),
            ManagedServer(
                name: "mlx-audio (TTS + STT)",
                pipPackage: "mlx-audio[server] misaki[en]",
                command: "mlx_audio.server --host 127.0.0.1",
                port: 8081,
                role: .audio,
                note: "OpenAI-compatible /v1/audio/speech + /v1/audio/transcriptions. Kokoro needs misaki[en] (pulls spacy — use a Python 3.12 env, not 3.14). Pick the model per request in the Voice tab (e.g. TTS mlx-community/Kokoro-82M-bf16). Models download to ~/.cache/huggingface/hub on first use."
            ),
            ManagedServer(
                name: "mlx embeddings",
                pipPackage: "mlx-embeddings",
                command: "python ~/Konishi/python/mlx_embed_server.py --model ~/.lmstudio/models/AutomatosX/AX-Qwen3-Embedding-0.6B-MLX-AXQ-4bit",
                port: 7997,
                role: .embedding,
                note: "Native MLX embeddings server (no torch) exposing /v1/embeddings, so RAG/semantic memory runs on Apple Silicon while mlx serves chat. Konishi ships the server script; just install mlx-embeddings, point --model at a local mlx embedding model, Start, then 'Use for Embeddings'. Set the same id as your Embedding model in Settings."
            )
        ]
    }
}
