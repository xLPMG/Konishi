import Foundation

struct DetectedEndpoint: Identifiable, Equatable, Sendable {
    let port: Int
    let modelIDs: [String]

    var id: Int { port }
    var baseURL: String { "http://127.0.0.1:\(port)" }
}

enum LocalEndpointDiscovery {
    private static let ports = [1234, 5000, 5001, 7860, 7997, 8000, 8001, 8080, 8081, 9000, 11434]

    private struct ModelsResponse: Decodable {
        struct Item: Decodable { let id: String }
        let data: [Item]
    }

    static func scan() async -> [DetectedEndpoint] {
        await withTaskGroup(of: DetectedEndpoint?.self, returning: [DetectedEndpoint].self) { group in
            for port in ports {
                group.addTask { await probe(port: port) }
            }
            var endpoints: [DetectedEndpoint] = []
            for await endpoint in group {
                if let endpoint { endpoints.append(endpoint) }
            }
            return endpoints.sorted { $0.port < $1.port }
        }
    }

    static func modelIDs(from data: Data) -> [String] {
        (try? JSONDecoder().decode(ModelsResponse.self, from: data))?.data.map(\.id) ?? []
    }

    private static func probe(port: Int) async -> DetectedEndpoint? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/models") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.25
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode != 404 else { return nil }
            return DetectedEndpoint(port: port, modelIDs: modelIDs(from: data))
        } catch {
            return nil
        }
    }
}