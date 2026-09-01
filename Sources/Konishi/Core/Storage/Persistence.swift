import Foundation

enum Persistence {
    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()

    /// Serial queue for disk writes: encode on the caller's context (correct snapshot),
    /// write off-main in submission order so the UI never stalls on JSON I/O and
    /// saves/deletes to the same file stay consistent.
    nonisolated static let ioQueue = DispatchQueue(label: "konishi.persistence", qos: .utility)
}
