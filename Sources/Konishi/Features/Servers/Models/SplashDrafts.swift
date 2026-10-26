import Foundation

/// The DFlash2 drafts Splash releases per model family, mirrored from Splash's `install/families.py`,
/// and the Hugging Face cache check Splash's local-file preparation relies on.
enum SplashDrafts {
    private static let families: [(markers: [String], repository: String)] = [
        (["qwen3.8-27b"], "incoai/Qwen3.8-27B-DFlash2"),
        (["qwen3.6-35b-a3b"], "incoai/Qwen3.6-35B-A3B-DFlash2"),
        (["qwen3.5-122b-a10b", "ornith-1.5-122b"], "incoai/Ornith-1.5-122B-DFlash2"),
        (["qwen3.8-flash-next"], "incoai/Qwen3.8-Flash-Next-DFlash2"),
        (["flint"], "incoai/Flint-DFlash2")
    ]

    /// The draft repository for a model path or ID, matched by name; nil when the family is not recognised.
    static func repository(forModel model: String?) -> String? {
        guard let model else { return nil }
        let name = model.lowercased()
        return families.first { family in family.markers.contains { name.contains($0) } }?.repository
    }

    /// Preparing local files asks no Hub, so it needs the cache to record the commit of the draft's default branch.
    static func isCached(
        _ repository: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let hub: URL
        if let cache = environment["HF_HUB_CACHE"], !cache.isEmpty {
            hub = URL(fileURLWithPath: (cache as NSString).expandingTildeInPath)
        } else if let hfHome = environment["HF_HOME"], !hfHome.isEmpty {
            hub = URL(fileURLWithPath: (hfHome as NSString).expandingTildeInPath).appendingPathComponent("hub")
        } else {
            hub = home.appendingPathComponent(".cache/huggingface/hub")
        }
        let folder = hub.appendingPathComponent("models--" + repository.replacingOccurrences(of: "/", with: "--"))
        guard let commit = try? String(contentsOf: folder.appendingPathComponent("refs/main"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !commit.isEmpty else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("snapshots/\(commit)").path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    /// A readable reason for a failed Splash start, taken from its log; nil when the log shows nothing recognisable.
    static func failureReason(in output: String) -> String? {
        let incompatible = [
            ManagedServer.splashIncompatibleMarker,
            "No module named 'install",
            "No module named 'server",
            "cannot import name 'prepare_local_model'",
            "unrecognized arguments"
        ]
        if incompatible.contains(where: output.contains) {
            return "Splash's launch interface no longer matches this version of Konishi. Check the installed Splash version, update Konishi, or start the model with `splash serve`."
        }
        guard let line = output.split(whereSeparator: \.isNewline).last(where: { $0.contains("ModelError:") }),
              let range = line.range(of: "ModelError:") else { return nil }
        var reason = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        if reason.contains("no DFlash2 draft is released") {
            reason += " Set a draft path in the server settings."
        }
        return reason.isEmpty ? nil : reason
    }
}
