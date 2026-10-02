import XCTest
@testable import Konishi

final class FileStoreTests: XCTestCase {
    func testWriteCreatesNestedWorkspaceFile() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let destination = try FileStore().write(
            path: "reports/example_text.txt", content: "hello workspace", in: workspace)

        XCTAssertEqual(
            try String(contentsOf: destination, encoding: .utf8), "hello workspace")
    }

    func testResolveRejectsParentTraversal() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        XCTAssertThrowsError(
            try FileStore().resolveWorkspacePath("../outside.txt", in: workspace))
    }

    func testResolveRejectsSymbolicLinkEscape() throws {
        let workspace = try makeWorkspace()
        let outside = try makeWorkspace()
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: outside)
        }
        let link = workspace.appendingPathComponent("outside")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertThrowsError(
            try FileStore().resolveWorkspacePath("outside/file.txt", in: workspace))
    }

    private func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Konishi-FileStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}