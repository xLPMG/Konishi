import Foundation

extension AppModel {
    var currentTrace: [TraceEntry] {
        selectedConversationID.flatMap { traceStore.traces[$0] } ?? []
    }

    func requestSummary(
        config: RequestConfig, wire: [WireMessage], tools: [ToolDef]?, memory: String,
        summary: String
    ) -> String {
        let roles = wire.map { $0.role }.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
            .map { "\($0.key):\($0.value)" }.sorted().joined(separator: " ")
        var lines = [
            "model=\(config.model)  temp=\(config.temperature)  maxTokens=\(config.maxTokens.map(String.init) ?? "default")"
        ]
        lines.append("messages=\(wire.count) [\(roles)]")
        if let tools, !tools.isEmpty {
            lines.append("tools=[\(tools.map(\.function.name).joined(separator: ", "))]")
        }
        if !summary.isEmpty { lines.append("summary injected (\(summary.count) chars)") }
        if !memory.isEmpty { lines.append("memory injected (\(memory.count) chars)") }
        return lines.joined(separator: "\n")
    }

    /// The full assembled request (every message, in order) for on-demand display in the Trace.
    func requestDetail(wire: [WireMessage]) -> String {
        var out: [String] = []
        for msg in wire {
            out.append("── \(msg.role) ──")
            switch msg.content {
            case .text(let s):
                out.append(s)
            case .parts(let parts):
                for p in parts {
                    if p.type == "image_url" {
                        let u = p.imageUrl?.url ?? ""
                        out.append(
                            u.hasPrefix("data:")
                                ? "[image: \(u.prefix(30))… (\(u.count) chars)]" : "[image: \(u)]")
                    } else {
                        out.append(p.text ?? "")
                    }
                }
            case .none:
                break
            }
            if let calls = msg.toolCalls {
                for c in calls {
                    out.append("→ tool_call \(c.function.name ?? "?")(\(c.function.arguments))")
                }
            }
            if let tid = msg.toolCallId { out.append("(tool_call_id: \(tid))") }
            out.append("")
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
