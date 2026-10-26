import Foundation
import Testing

@testable import Konishi

@Suite("Managed server configuration")
struct ManagedServerTests {
    @Test("model selection stays separate and safely quotes paths containing spaces")
    func modelPathSelection() {
        var server = ManagedServer.presets[0]
        let path = "/Models/My Chat Model"

        server.setModelPath(path)

        #expect(server.modelPath == path)
        #expect(!server.command.contains("--model"))
        #expect(server.launchCommand.contains("--model '\(path)'"))
        #expect(server.launchCommand.contains("--host '127.0.0.1' --port 8080"))
    }

    @Test("Splash starts from a local model directory but advertises its API model ID")
    func splashLocalModelLaunch() {
        var server = ManagedServer.presets.first { $0.builtInServer == .splash }!
        let path = "/Models/Qwen 3.8 Splash"

        server.setModelPath(path)
        let command = server.launchCommand

        #expect(server.apiModelID == "mlx-community/Qwen3.8-27B-4bit")
        #expect(command.contains("MODEL_SOURCE='/Models/Qwen 3.8 Splash'"))
        #expect(command.contains("-m server.server \"$MODEL_DIR\""))
        #expect(command.contains("from install.local import prepare_local_model"))
        #expect(command.contains("prepare_local_model(sys.argv[1], draft=sys.argv[2] if len(sys.argv) > 2 else None)"))
        #expect(!command.contains("DRAFT_SOURCE"))
        #expect(command.contains("sys.stdout = sys.stderr"))
        #expect(command.contains("sys.stdout = stdout; print(model)"))
        #expect(!command.contains("--tokenizer"))
        #expect(command.contains("--model \"$MODEL_ID\""))
        #expect(command.contains("MODEL_ID='mlx-community/Qwen3.8-27B-4bit'"))
        #expect(command.contains("\(ManagedServer.splashIncompatibleMarker)"))
        #expect(command.contains("; export PYTHONPATH=\"$SPLASH_ROOT\"; MODEL_DIR="))
        #expect(command.contains("; exec \"$SPLASH_ROOT/python/bin/python3\""))
        #expect(command.contains("--port 8080"))
        #expect(!command.contains("--model '/Models/Qwen 3.8 Splash'"))
    }

    @Test("Splash derives its API model ID from the selected LM Studio folder")
    func splashModelIDTracksSelectedFolder() {
        var server = ManagedServer.presets.first { $0.builtInServer == .splash }!
        server.setModelPath("/Users/me/.lmstudio/models/incoai/Qwen3.6-35B-A3B-Splash")

        #expect(server.effectiveAPIModelID == "incoai/Qwen3.6-35B-A3B-Splash")
        #expect(server.launchCommand.contains("MODEL_ID='incoai/Qwen3.6-35B-A3B-Splash'"))

        server.configureBuiltInServer(.splash)
        #expect(server.effectiveAPIModelID == "incoai/Qwen3.6-35B-A3B-Splash")
    }

    @Test("Splash passes an explicit draft directory to preparation")
    func splashExplicitDraft() {
        var server = ManagedServer.presets.first { $0.builtInServer == .splash }!
        server.setModelPath("/Models/Target")
        server.draftModel = "~/Drafts/My Draft"
        let command = server.launchCommand

        #expect(command.contains("DRAFT_SOURCE=\"$HOME\"/'Drafts/My Draft'; "))
        #expect(command.contains("\"$MODEL_SOURCE\" \"$DRAFT_SOURCE\""))
        #expect(server.splashRequiredDraftRepository == nil)
    }

    @Test("Splash serves a Hugging Face ID itself and downloads its own draft")
    func splashHubModelLaunch() {
        var server = ManagedServer.presets.first { $0.builtInServer == .splash }!
        server.setModelPath("unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M")
        let command = server.launchCommand

        #expect(server.splashUsesHubModel)
        #expect(server.effectiveAPIModelID == "unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M")
        #expect(command.contains("\"$SPLASH_BIN\" serve --model 'unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M'"))
        #expect(command.contains("--served-model-name 'unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M' --announce-served-name"))
        #expect(command.contains("--host '127.0.0.1' --port 8080"))
        #expect(!command.contains("prepare_local_model"))
        #expect(!command.contains("--draft-model"))
        #expect(server.splashRequiredDraftRepository == nil)

        server.draftModel = "/Drafts/D"
        #expect(server.launchCommand.contains("--draft-model '/Drafts/D'"))

        server.setModelPath("~/.lmstudio/models/mlx-community/Qwen3.8-27B-4bit")
        #expect(!server.splashUsesHubModel)
    }

    @Test("Splash draft repository is recognised from the model name")
    func splashDraftRepositoryLookup() {
        var server = ManagedServer.presets.first { $0.builtInServer == .splash }!
        server.setModelPath("~/.lmstudio/models/mlx-community/Qwen3.8-27B-4bit")
        #expect(server.splashRequiredDraftRepository == "incoai/Qwen3.8-27B-DFlash2")
        #expect(SplashDrafts.repository(forModel: "/m/Qwen3.6-35B-A3B-4bit") == "incoai/Qwen3.6-35B-A3B-DFlash2")
        #expect(SplashDrafts.repository(forModel: "/m/gemma-4-26B") == nil)
    }

    @Test("Splash draft cache check needs the default branch recorded with its snapshot")
    func splashDraftCacheCheck() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home.appendingPathComponent(".cache/huggingface/hub/models--incoai--Qwen3.8-27B-DFlash2")
        let repo = "incoai/Qwen3.8-27B-DFlash2"

        #expect(!SplashDrafts.isCached(repo, environment: [:], home: home))

        try FileManager.default.createDirectory(at: folder.appendingPathComponent("refs"), withIntermediateDirectories: true)
        try "abc123\n".write(to: folder.appendingPathComponent("refs/main"), atomically: true, encoding: .utf8)
        #expect(!SplashDrafts.isCached(repo, environment: [:], home: home))

        try FileManager.default.createDirectory(at: folder.appendingPathComponent("snapshots/abc123"), withIntermediateDirectories: true)
        #expect(SplashDrafts.isCached(repo, environment: [:], home: home))
        #expect(!SplashDrafts.isCached(repo, environment: ["HF_HUB_CACHE": home.appendingPathComponent("elsewhere").path], home: home))
    }

    @Test("Splash start failures produce readable reasons")
    func splashFailureReasons() {
        let unreleased = "install.models.ModelError: cannot prepare /m/x: no DFlash2 draft is released for Foo; pass the directory of one as draft"
        #expect(SplashDrafts.failureReason(in: "Traceback\n\(unreleased)\n")?.hasSuffix("Set a draft path in the server settings.") == true)
        #expect(SplashDrafts.failureReason(in: "\(ManagedServer.splashIncompatibleMarker): gone")?.contains("launch interface") == true)
        #expect(SplashDrafts.failureReason(in: "server.py: error: unrecognized arguments: --binary")?.contains("launch interface") == true)
        #expect(SplashDrafts.failureReason(in: "exited with code 1") == nil)
    }

    @Test("missing Splash draft error identifies the repository")
    func missingSplashDraftDetection() {
        let output = """
        install.models.ModelError: cannot resolve incoai/Qwen3.6-35B-A3B: no draft was given, and preparing local files asks no Hub; the Hub cache records no commit for the default branch; download incoai/Qwen3.6-35B-A3B-DFlash2, or pass the directory of a Qwen3.6-35B-A3B DFlash2 draft as draft
        """

        #expect(Runtime.missingSplashDraft(in: output) == "incoai/Qwen3.6-35B-A3B-DFlash2")
        #expect(Runtime.missingSplashDraft(in: "server exited with code 1") == nil)
    }

    @Test("built-in Chat switches its fixed server when vision is enabled")
    func builtInChatVisionToggle() {
        var chat = ManagedServer.presets[0]

        #expect(chat.builtInServer == .mlxLMChat)
        #expect(ManagedServer.presets.filter { $0.builtInServer?.isChat == true }.count == 1)

        chat.setVisionServer(true)

        #expect(chat.builtInServer == .mlxVLMChat)
        #expect(chat.pipPackage == "mlx-vlm")
        #expect(chat.command == "mlx_vlm.server")
        #expect(chat.modelPath == "mlx-community/gemma-4-12B-it-qat-4bit")

        chat.setVisionServer(false)

        #expect(chat.builtInServer == .mlxLMChat)
        #expect(chat.pipPackage == "mlx-lm")
        #expect(chat.command == "mlx_lm.server")
    }

    @Test("custom server marker survives encoding")
    func customMarkerPersistence() throws {
        let custom = ManagedServer(
            name: "My VLM",
            pipPackage: "mlx-vlm",
            command: "mlx_vlm.server",
            host: "127.0.0.1",
            port: 8090,
            role: .chat,
            note: "",
            isCustom: true
        )

        let data = try JSONEncoder().encode(custom)
        let decoded = try JSONDecoder().decode(ManagedServer.self, from: data)

        #expect(decoded.isCustom)
        #expect(decoded.builtInServer == nil)
    }

    @Test("local endpoint model response decodes model identifiers")
    func endpointModelsDecode() {
        let data = Data(#"{"data":[{"id":"mlx-chat"},{"id":"embedder"}]}"#.utf8)
        #expect(LocalEndpointDiscovery.modelIDs(from: data) == ["mlx-chat", "embedder"])
    }
}