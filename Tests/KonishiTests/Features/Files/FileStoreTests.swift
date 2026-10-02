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
            try PathScope.resolve("../outside.txt", in: workspace))
    }

    func testWriteSupportsAbsoluteExternalPaths() throws {
        let workspace = try makeWorkspace()
        let external = try makeWorkspace()
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: external)
        }
        let destination = external.appendingPathComponent("notes/output.md")

        let written = try FileStore().write(
            path: destination.path, content: "external", in: workspace)

        XCTAssertEqual(written.path, destination.path)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "external")
    }

    func testWriteRejectsAPathDifferentFromTheEvaluatedPath() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        XCTAssertThrowsError(try FileStore().write(
            path: "report.md", content: "no", in: workspace,
            expectedResolvedPath: "/another/location/report.md"))
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
            try PathScope.resolve("outside/file.txt", in: workspace))
    }

    private func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Konishi-FileStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}