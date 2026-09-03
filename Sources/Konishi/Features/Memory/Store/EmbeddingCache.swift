import CryptoKit
import Foundation

/// Disk-backed cache of text embeddings, keyed by (model, text) hash.
/// Memory blocks are stable, so this avoids re-embedding them every turn.
/// Vectors are stored as `Float` in a compact binary file (half the size of JSON `Double`),
/// and writes are debounced so a turn that only reads doesn't rewrite the whole store.
@MainActor
final class EmbeddingCache {
    private var store: [String: [Float]]
    private let url = Paths.cache.appendingPathComponent("embeddings.bin")
    private var dirty = false
    private var saveTask: Task<Void, Never>?

    nonisolated private static let magic: [UInt8] = [0x4B, 0x45, 0x4D, 0x42]  // "KEMB"
    nonisolated private static let version: UInt8 = 1

    init() {
        store = Self.load(from: url)
    }

    private func key(model: String, text: String) -> String {
        let digest = SHA256.hash(data: Data((model + "\u{0}" + text).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func get(model: String, text: String) -> [Double]? {
        store[key(model: model, text: text)]?.map(Double.init)
    }

    func set(model: String, text: String, embedding: [Double]) {
        store[key(model: model, text: text)] = embedding.map(Float.init)
        dirty = true
    }

    /// Debounced: coalesces bursts of `set` calls in a turn into a single disk write.
    func save() {
        guard dirty else { return }
        saveTask?.cancel()
        let snapshot = store
        let url = url
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await Task.detached { Self.write(snapshot, to: url) }.value
            self?.dirty = false
        }
    }

    /// Embeds the query plus only the memory blocks not already cached (blocks are stable).
    func embedWithCache(
        query: String, blocks: [String], requestConfig: RequestConfig
    ) async throws -> (
        query: [Double], blocks: [[Double]]
    ) {
        var blockEmb = [[Double]?](repeating: nil, count: blocks.count)
        var missing: [Int] = []
        for (i, b) in blocks.enumerated() {
            if let e = self.get(model: requestConfig.embeddingModel, text: b) {
                blockEmb[i] = e
            } else {
                missing.append(i)
            }
        }
        let inputs = [query] + missing.map { blocks[$0] }
        let result = try await ChatService.embed(config: requestConfig, inputs: inputs)
        guard result.count == inputs.count else { throw ChatServiceError.invalidURL }
        for (k, idx) in missing.enumerated() {
            let e = result[k + 1]
            blockEmb[idx] = e
            self.set(model: requestConfig.embeddingModel, text: blocks[idx], embedding: e)
        }
        self.save()
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

    // MARK: Binary codec

    nonisolated private static func write(_ store: [String: [Float]], to url: URL) {
        var data = Data()
        data.append(contentsOf: magic)
        data.append(version)
        var count = UInt32(store.count).littleEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        for (k, vec) in store {
            let keyBytes = Array(k.utf8)
            var keyLen = UInt16(keyBytes.count).littleEndian
            withUnsafeBytes(of: &keyLen) { data.append(contentsOf: $0) }
            data.append(contentsOf: keyBytes)
            var dim = UInt32(vec.count).littleEndian
            withUnsafeBytes(of: &dim) { data.append(contentsOf: $0) }
            for f in vec {
                var bits = f.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
            }
        }
        try? data.write(to: url, options: .atomic)
    }

    nonisolated private static func load(from url: URL) -> [String: [Float]] {
        guard let data = try? Data(contentsOf: url), data.count >= 9,
            Array(data.prefix(4)) == magic
        else { return [:] }
        var offset = 5  // magic(4) + version(1)
        func read<T>(_ type: T.Type) -> T? where T: FixedWidthInteger {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { return nil }
            let value = data.subdata(in: offset..<offset + size).withUnsafeBytes {
                $0.loadUnaligned(as: T.self)
            }
            offset += size
            return T(littleEndian: value)
        }
        guard let count = read(UInt32.self) else { return [:] }
        var result: [String: [Float]] = [:]
        result.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let keyLen = read(UInt16.self), offset + Int(keyLen) <= data.count else { break }
            let key = String(
                decoding: data.subdata(in: offset..<offset + Int(keyLen)), as: UTF8.self)
            offset += Int(keyLen)
            guard let dim = read(UInt32.self) else { break }
            var vec = [Float]()
            vec.reserveCapacity(Int(dim))
            for _ in 0..<dim {
                guard let bits = read(UInt32.self) else { break }
                vec.append(Float(bitPattern: bits))
            }
            result[key] = vec
        }
        return result
    }
}
