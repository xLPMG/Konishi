import SwiftUI

struct TraceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pinned = true
    @State private var expanded: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Trace").font(.headline)
                Spacer()
                Text("\(model.currentTrace.count) events").font(.caption).foregroundStyle(.secondary)
                Button {
                    let text = model.currentTrace.map(Self.line).joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                Button("Clear") {
                    if let id = model.selectedConversationID { model.traceStore.clearTrace(conversationID: id) }
                }
                Button("Done") { dismiss() }
            }
            .padding(10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(model.currentTrace) { entry in
                            row(entry).id(entry.id)
                        }
                        if model.currentTrace.isEmpty {
                            Text("No events yet. Send a message to see the request/response trace.")
                                .foregroundStyle(.secondary).padding()
                        }
                    }
                    .padding(10)
                }
                .onScrollGeometryChange(for: Bool.self) { geo in
                    geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 40
                } action: { _, atBottom in
                    pinned = atBottom
                }
                .onChange(of: model.currentTrace.count) {
                    guard pinned, let last = model.currentTrace.last else { return }
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 460)
        .background(model.currentPalette.canvas.ignoresSafeArea())
        .onAppear {
            if let id = model.selectedConversationID { model.traceStore.ensureTraceLoaded(conversationID: id) }
        }
        .onChange(of: model.selectedConversationID) { _, id in
            if let id { model.traceStore.ensureTraceLoaded(conversationID: id) }
        }
    }

    private func row(_ entry: TraceEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: Self.symbol(entry.kind))
                    .foregroundStyle(Self.color(entry.kind))
                Text(entry.kind.rawValue.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Self.color(entry.kind))
                Text(entry.date, format: .dateTime.hour().minute().second())
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(entry.text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let detail = entry.detail, !detail.isEmpty {
                let isOpen = expanded.contains(entry.id)
                Button {
                    if isOpen { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
                } label: {
                    Label(isOpen ? "Hide details" : "Show details",
                          systemImage: isOpen ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                if isOpen {
                    ScrollView {
                        Text(detail)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 260)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .topTrailing) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(detail, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.plain).padding(6).help("Copy details")
                    }
                }
            }
        }
        .padding(8)
        .background(Self.color(entry.kind).opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private static func line(_ e: TraceEntry) -> String {
        let t = e.date.formatted(.dateTime.hour().minute().second())
        return "\(t) [\(e.kind.rawValue)] \(e.text)"
    }

    private static func symbol(_ kind: TraceEntry.Kind) -> String {
        switch kind {
        case .request: "arrow.up.circle"
        case .token: "bolt"
        case .reasoning: "brain"
        case .usage: "number"
        case .tool: "wrench.and.screwdriver"
        case .result: "arrow.down.circle"
        case .finish: "flag.checkered"
        case .error: "exclamationmark.triangle"
        case .info: "info.circle"
        case .compress: "arrow.down.right.and.arrow.up.left"
        case .memory: "tray.full"
        }
    }

    private static func color(_ kind: TraceEntry.Kind) -> Color {
        switch kind {
        case .request: .blue
        case .token: .green
        case .reasoning: .purple
        case .usage: .teal
        case .tool: .orange
        case .result: .indigo
        case .finish: .gray
        case .error: .red
        case .info: .secondary
        case .compress: .brown
        case .memory: .pink
        }
    }
}
