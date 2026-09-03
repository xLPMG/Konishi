import Foundation

extension AppModel {
    /// Describes an embedding failure, hinting at the common cause (server has no embeddings endpoint).
    static func embedErrorHint(_ error: Error) -> String {
        "\(error.localizedDescription) — needs a chat server exposing /v1/embeddings with an embedding model loaded"
    }

    /// Embeds the query plus only the memory blocks not already cached (blocks are stable).
    func embedWithCache(query: String, blocks: [String], model: String) async throws -> (
        query: [Double], blocks: [[Double]]
    ) {
        var blockEmb = [[Double]?](repeating: nil, count: blocks.count)
        var missing: [Int] = []
        for (i, b) in blocks.enumerated() {
            if let e = embeddingCache.get(model: model, text: b) {
                blockEmb[i] = e
            } else {
                missing.append(i)
            }
        }
        let inputs = [query] + missing.map { blocks[$0] }
        let config = settings.requestConfig(modelOverride: nil)
        let result = try await ChatService.embed(config: config, inputs: inputs)
        guard result.count == inputs.count else { throw ChatServiceError.invalidURL }
        for (k, idx) in missing.enumerated() {
            let e = result[k + 1]
            blockEmb[idx] = e
            embeddingCache.set(model: model, text: blocks[idx], embedding: e)
        }
        embeddingCache.save()
        return (result[0], blockEmb.map { $0 ?? [] })
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0
        var na = 0.0
        var nb = 0.0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = na.squareRoot() * nb.squareRoot()
        return denom == 0 ? 0 : dot / denom
    }
}
