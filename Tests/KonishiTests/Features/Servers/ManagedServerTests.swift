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

        #expect(server.apiModelID == "incoai/Qwen3.8-27B-Splash")
        #expect(command.contains("MODEL_DIR='/Models/Qwen 3.8 Splash'"))
        #expect(command.contains("-m server.server \"$MODEL_DIR\""))
        #expect(command.contains("--tokenizer \"$MODEL_DIR/tokenizer\""))
        #expect(command.contains("--model \"$MODEL_ID\""))
        #expect(command.contains("MODEL_ID='incoai/Qwen3.8-27B-Splash'"))
        #expect(command.contains("; export PYTHONPATH=\"$SPLASH_ROOT\"; exec \"$SPLASH_ROOT/python/bin/python3\""))
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