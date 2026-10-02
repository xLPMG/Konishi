import Foundation
import Testing

@testable import Konishi

@Suite("Path scope")
struct PathScopeTests {
    @Test("rejects relative parent traversal outside workspace")
    func rejectsParentTraversal() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        #expect(throws: PathScope.PathError.self) {
            try PathScope.resolve("../outside.txt", in: workspace)
        }
    }

    @Test("classifies absolute paths inside the workspace as workspace paths")
    func resolvesAbsoluteWorkspacePath() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let file = workspace.appendingPathComponent("report.md")

        let resolved = try PathScope.resolve(file.path, in: workspace)

        #expect(resolved.isWithinWorkspace)
        #expect(resolved.url.path == file.path)
    }

    @Test("expands home-relative paths")
    func expandsHomeRelativePaths() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let resolved = try PathScope.resolve("~/Documents/notes.md", in: workspace)

        #expect(resolved.url.path == FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/notes.md").path)
        #expect(!resolved.isWithinWorkspace)
    }

    @Test("resolves a missing child beneath a symlinked parent")
    func resolvesMissingChildUnderSymlink() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let target = workspace.appendingPathComponent("actual", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = workspace.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let resolved = try PathScope.resolve("linked/new/file.md", in: workspace)

        #expect(resolved.url.path == target.appendingPathComponent("new/file.md").path)
        #expect(resolved.isWithinWorkspace)
    }

    @Test("rejects a symlink escape for relative paths")
    func rejectsSymlinkEscape() throws {
        let workspace = try makeWorkspace()
        let outside = try makeWorkspace()
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent("outside"), withDestinationURL: outside)

        #expect(throws: PathScope.PathError.self) {
            try PathScope.resolve("outside/file.md", in: workspace)
        }
    }

    @Test("path containment is case insensitive and component bounded")
    func pathContainmentIsCaseInsensitiveAndBounded() {
        #expect(PathScope.path("/Users/A/Workspace/Reports/a.md", isWithin: "/users/a/workspace/reports"))
        #expect(!PathScope.path("/workspace/reports-old/a.md", isWithin: "/workspace/reports"))
    }

    @Test("classifies another conversation workspace as external")
    func otherWorkspaceIsExternal() throws {
        let first = try makeWorkspace()
        let second = try makeWorkspace()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let context = ToolPermissionContext(mode: .chat, workspace: first)
        let classified = try ToolPermissions.classify(
            toolName: "file_read", arguments: ["path": .string(second.appendingPathComponent("x.md").path)],
            context: context)

        #expect(classified?.first?.capability == .externalRead)
    }

    @Test("another conversation's Files folder is protected")
    func otherConversationFilesAreProtected() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Konishi-ProtectedTests-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("files/current", isDirectory: true)
        let otherWorkspace = root.appendingPathComponent("files/other", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherWorkspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let currentReason = ProtectedLocations.reason(
            for: workspace.appendingPathComponent("draft.md").path,
            workspace: workspace, konishiRoot: root)
        let otherReason = ProtectedLocations.reason(
            for: otherWorkspace.appendingPathComponent("draft.md").path,
            workspace: workspace, konishiRoot: root)

        #expect(currentReason == nil)
        #expect(otherReason != nil)
    }

    private func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Konishi-PathScopeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}