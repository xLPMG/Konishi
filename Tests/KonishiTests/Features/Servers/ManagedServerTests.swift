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