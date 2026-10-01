import Foundation
import Testing

@testable import Konishi

@Suite("Managed server configuration")
struct ManagedServerTests {
    @Test("model selection safely replaces a path containing spaces")
    func modelPathSelection() {
        var server = ManagedServer.presets[0]
        let path = "/Models/My Chat Model"

        server.setModelPath(path)

        #expect(server.modelPath == path)
        #expect(server.launchCommand.contains("--model '\(path)'"))
        #expect(server.launchCommand.contains("--host '127.0.0.1' --port 8080"))
    }

    @Test("local endpoint model response decodes model identifiers")
    func endpointModelsDecode() {
        let data = Data(#"{"data":[{"id":"mlx-chat"},{"id":"embedder"}]}"#.utf8)
        #expect(LocalEndpointDiscovery.modelIDs(from: data) == ["mlx-chat", "embedder"])
    }
}