import SwiftUI

struct AutopilotPermissionSummary: View {
    @Environment(AppModel.self) private var model
    var compact = false

    var body: some View {
        if let conversationID = model.workSession?.conversationID ?? model.selectedConversationID {
            summary(for: conversationID)
        } else {
            Text("Select a conversation to preview Autopilot permissions.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func summary(for conversationID: UUID) -> some View {
        let interactive = model.toolPermissionContext(
            conversationID: conversationID, surface: .interactive)
        let unattended = model.toolPermissionContext(
            conversationID: conversationID, surface: .unattended)
        let interactiveTools = ToolPermissions.visibleTools(context: interactive)
        let unattendedTools = ToolPermissions.visibleTools(context: unattended)
        let allowed = Set(ToolPermissions.allowedCapabilities(context: unattended))
        let candidates = Set(interactiveTools.flatMap {
            ToolPermissions.possibleCapabilities(for: $0.name)
        }.filter { $0 != .userInput })
        let blocked = candidates.filter { !allowed.contains($0) }.sorted { $0.rawValue < $1.rawValue }

        return VStack(alignment: .leading, spacing: compact ? 3 : 8) {
            if !compact {
                HStack {
                    Label("Autopilot permissions", systemImage: "infinity")
                        .font(.headline)
                    Spacer()
                    if model.autopilotArmed { Text("Armed").font(.caption).foregroundStyle(model.currentAccent) }
                }
            }
            Text("Allowed: \(allowed.isEmpty ? "none" : allowed.map(\.label).sorted().joined(separator: ", ")).")
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.secondary)
            Text("Tools: \(toolList(unattendedTools.map(\.name))).")
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.secondary)
            if !interactive.toolsEnabled {
                Text("Tool calling is off for \(interactive.mode.label); no tools will be exposed.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            if !blocked.isEmpty {
                if !compact { Text("Needs a human").font(.caption.weight(.semibold)) }
                ForEach(blocked, id: \.self) { capability in
                    HStack(spacing: 6) {
                        Text(capability.label)
                            .font(compact ? .caption2 : .caption)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if !compact {
                            Button("Allow for this conversation") {
                                model.allowCapabilityForConversation(
                                    capability, conversationID: conversationID)
                            }
                            .font(.caption)
                            .buttonStyle(.borderless)
                        }
                    }
                }
            } else if !compact, interactive.toolsEnabled {
                Text("No enabled capability needs human permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !model.autopilotBlockedCapabilities.isEmpty {
                Text("Blocked this run: \(model.autopilotBlockedCapabilities.joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(compact ? 1 : 3)
            }
            Text("Ask decisions and protected locations are denied during Autopilot.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(compact ? 0 : 12)
    }

    private func toolList(_ names: [String]) -> String {
        guard !names.isEmpty else { return "none" }
        let shown = names.prefix(compact ? 5 : 10).joined(separator: ", ")
        return names.count > (compact ? 5 : 10) ? "\(shown), and \(names.count - (compact ? 5 : 10)) more" : shown
    }
}