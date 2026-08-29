import SwiftUI

/// A circular ring that fills with context usage; shows the numeric value on hover or click.
struct ContextGauge: View {
    let used: Int
    let window: Int?
    @State private var showDetail = false

    private var fraction: Double {
        guard let window, window > 0 else { return 0 }
        return min(Double(used) / Double(window), 1)
    }

    private var tint: Color {
        switch fraction {
        case ..<0.7: .green
        case ..<0.9: .yellow
        default: .red
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 3)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if window == nil {
                Image(systemName: "questionmark")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 20, height: 20)
        .contentShape(Rectangle())   // make the whole frame hoverable/clickable, not just the ring
        .help(helpText)
        .onTapGesture { showDetail.toggle() }
        .popover(isPresented: $showDetail, arrowEdge: .bottom) {
            Text(helpText)
                .font(.callout).monospacedDigit()
                .textSelection(.enabled)
                .padding(10)
        }
        .animation(.easeOut(duration: 0.3), value: fraction)
    }

    private var helpText: String {
        guard let window else {
            return "Context: \(used) tokens used — window size unknown. Set an override in Settings › Generation."
        }
        let pct = Int(fraction * 100)
        return "Context: \(used) / \(window) tokens (\(pct)%)"
    }
}

/// Slim metrics row: generation status + TTFT/tokens-per-second, with a context gauge.
struct StatsBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let stats = model.selectedConversation?.lastStats
        HStack(spacing: 14) {
            ModelChip()
            if model.isStreaming {
                Label("Generating", systemImage: "circle.fill")
                    .foregroundStyle(.green).symbolEffect(.pulse)
            }
            if !model.activeToolNames.isEmpty {
                Label("\(model.activeToolNames.count) tools", systemImage: "wrench.and.screwdriver")
                    .foregroundStyle(model.currentAccent)
                    .help("Tools available: " + model.activeToolNames.joined(separator: ", "))
            }
            if let s = model.selectedConversation?.summary, !s.isEmpty {
                Label("compressed", systemImage: "arrow.down.right.and.arrow.up.left")
                    .help("Older turns folded into a rolling summary")
            }
            if let ttft = stats?.timeToFirstToken {
                metric("bolt", String(format: "%.0f ms", ttft * 1000))
            }
            if let tps = stats?.tokensPerSecond {
                metric("gauge.with.dots.needle.67percent", String(format: "%.1f tok/s", tps))
            }
            if let ct = stats?.completionTokens {
                metric("text.word.spacing", "\(ct) tok")
            }
            Spacer()
            if model.connectionOK == false {
                Label("No server", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Can't reach the model server. Check Settings › Endpoints.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }

    private func metric(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).monospacedDigit()
    }
}

/// Compact model chooser for the metrics row: shows the current model and lets you switch quickly.
private struct ModelChip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Menu {
            if model.models.isEmpty {
                Text("No models found")
            } else if model.hasLoadState {
                Section("Loaded") {
                    ForEach(model.loadedModels) { info in modelButton(info, settings: settings) }
                }
                Section("Not loaded") {
                    ForEach(model.unloadedModels) { info in modelButton(info, settings: settings) }
                }
            } else {
                ForEach(model.models) { info in modelButton(info, settings: settings) }
            }
            Divider()
            Button("Refresh") { model.refreshServerInfo() }
        } label: {
            Label(shortModel, systemImage: "cpu")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Model: \(model.settings.model)")
    }

    private func modelButton(_ info: ModelInfo, settings: AppSettings) -> some View {
        Button {
            settings.model = info.id
        } label: {
            if info.isLoaded == true {
                Label(info.id, systemImage: "circle.fill")
            } else if info.isLoaded == false {
                Label(info.id, systemImage: "circle")
            } else {
                Text(info.id)
            }
        }
    }

    private var shortModel: String {
        let m = model.settings.model
        return m.count > 20 ? "…" + m.suffix(18) : m
    }
}
