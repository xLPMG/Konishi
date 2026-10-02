import Foundation

struct PathScope {
    enum PathError: LocalizedError, Equatable, Sendable {
        case empty
        case invalidTildePath
        case relativeEscape
        case pathChanged

        var errorDescription: String? {
            switch self {
            case .empty: "A file path is required."
            case .invalidTildePath: "Only paths beginning with ~/ are supported for home-relative paths."
            case .relativeEscape: "The relative path escapes this conversation's workspace."
            case .pathChanged: "The resolved path changed after permission was evaluated."
            }
        }
    }

    struct ResolvedPath: Equatable, Sendable {
        let url: URL
        let isWithinWorkspace: Bool
    }

    static func resolve(_ path: String, in workspace: URL) throws -> ResolvedPath {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0") else { throw PathError.empty }

        let root = canonicalURL(workspace)
        let expanded: URL
        if trimmed == "~" {
            expanded = FileManager.default.homeDirectoryForCurrentUser
        } else if trimmed.hasPrefix("~/") {
            expanded = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(trimmed.dropFirst(2)))
        } else if trimmed.hasPrefix("~") {
            throw PathError.invalidTildePath
        } else if (trimmed as NSString).isAbsolutePath {
            expanded = URL(fileURLWithPath: trimmed)
        } else {
            return try resolveRelative(trimmed, root: root)
        }

        let destination = canonicalURL(expanded)
        return ResolvedPath(url: destination, isWithinWorkspace: contains(root, destination))
    }

    static func canonicalURL(_ url: URL) -> URL {
        resolveExistingAncestor(url.standardizedFileURL)
    }

    static func canonicalPath(_ path: String) -> String {
        let expanded: URL
        if path == "~" {
            expanded = FileManager.default.homeDirectoryForCurrentUser
        } else if path.hasPrefix("~/") {
            expanded = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2)))
        } else {
            expanded = URL(fileURLWithPath: path)
        }
        return canonicalURL(expanded).path
    }

    static func contains(_ parent: URL, _ child: URL) -> Bool {
        path(child.path, isWithin: parent.path)
    }

    static func path(_ path: String, isWithin prefix: String) -> Bool {
        let child = normalizedForComparison(path)
        let root = normalizedForComparison(prefix)
        return child == root || child.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    static func pathPrefixMatches(_ path: String, prefix: String) -> Bool {
        self.path(canonicalPath(path), isWithin: canonicalPath(prefix))
    }

    static func pathsEqual(_ lhs: String, _ rhs: String) -> Bool {
        normalizedForComparison(canonicalPath(lhs)) == normalizedForComparison(canonicalPath(rhs))
    }

    private static func resolveRelative(_ path: String, root: URL) throws -> ResolvedPath {
        var current = root
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..":
                current.deleteLastPathComponent()
            default:
                current.appendPathComponent(String(component))
                current = resolveExistingAncestor(current)
            }
            current = current.standardizedFileURL
            guard contains(root, current) else { throw PathError.relativeEscape }
        }
        return ResolvedPath(url: current, isWithinWorkspace: true)
    }

    private static func resolveExistingAncestor(_ url: URL) -> URL {
        var ancestor = url.standardizedFileURL
        var missing: [String] = []
        let fileManager = FileManager.default

        while !existsOrIsSymbolicLink(ancestor, fileManager: fileManager), ancestor.path != "/" {
            missing.insert(ancestor.lastPathComponent, at: 0)
            ancestor.deleteLastPathComponent()
        }

        ancestor = ancestor.resolvingSymlinksInPath().standardizedFileURL
        for component in missing {
            ancestor.appendPathComponent(component)
        }
        return ancestor.standardizedFileURL
    }

    private static func existsOrIsSymbolicLink(_ url: URL, fileManager: FileManager) -> Bool {
        if fileManager.fileExists(atPath: url.path) { return true }
        return (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private static func normalizedForComparison(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let folded = standardized.lowercased()
        if folded.count > 1, folded.hasSuffix("/") {
            return String(folded.dropLast())
        }
        return folded
    }
}