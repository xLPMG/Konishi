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

    @Test("previous built-in backend identity decodes into the unified server type")
    func legacyBuiltInBackendMigration() throws {
        let data = Data(#"{"id":"00000000-0000-0000-0000-000000000002","name":"Chat","pipPackage":"mlx-vlm","command":"mlx_vlm.server","model":"mlx-community/gemma-4-12B-it-qat-4bit","host":"127.0.0.1","port":8082,"role":"chat","note":"","builtInChatBackend":"mlxVLM"}"#.utf8)

        let server = try JSONDecoder().decode(ManagedServer.self, from: data)

        #expect(server.builtInServer == .mlxVLMChat)
        #expect(server.modelPath == "mlx-community/gemma-4-12B-it-qat-4bit")
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

    @Test("legacy model arguments migrate out of the saved command")
    func legacyModelCommandMigration() throws {
        let data = Data(#"{"id":"00000000-0000-0000-0000-000000000001","name":"mlx","pipPackage":"mlx-lm","command":"mlx_lm.server --model '~/Models/My Model'","host":"127.0.0.1","port":8080,"role":"chat","note":""}"#.utf8)

        let server = try JSONDecoder().decode(ManagedServer.self, from: data)

        #expect(server.command == "mlx_lm.server")
        #expect(server.modelPath == "~/Models/My Model")
        #expect(server.launchCommand.contains("--model \"$HOME\"/'Models/My Model'"))
    }

    @Test("local endpoint model response decodes model identifiers")
    func endpointModelsDecode() {
        let data = Data(#"{"data":[{"id":"mlx-chat"},{"id":"embedder"}]}"#.utf8)
        #expect(LocalEndpointDiscovery.modelIDs(from: data) == ["mlx-chat", "embedder"])
    }
}