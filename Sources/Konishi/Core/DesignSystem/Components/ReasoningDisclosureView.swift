import SwiftUI

struct AssistantActivityView: View {
    let text: String
    @State private var isAnimating = false

    private var displayText: String {
        let label: String
        if text.hasSuffix("…") {
            label = String(text.dropLast())
        } else if text.hasSuffix("...") {
            label = String(text.dropLast(3))
        } else {
            label = text
        }
        return label == "Thinking" ? "" : label
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 4, height: 4)
                        .opacity(isAnimating ? 0.35 : 0.9)
                        .offset(y: isAnimating ? 1 : -1)
                        .animation(
                            .easeInOut(duration: 0.55).repeatForever().delay(Double(index) * 0.14),
                            value: isAnimating
                        )
                }
            }
            .accessibilityHidden(true)

            if !displayText.isEmpty {
                Text(displayText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(displayText.isEmpty ? "Thinking" : displayText)
        .onAppear { isAnimating = true }
    }
}

struct ReasoningDisclosureView: View {
    @Environment(AppModel.self) private var model
    let reasoning: String
    var title: String = "Reasoning"
    var isGenerating = false
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            HStack(alignment: .top, spacing: 8) {
                model.currentPalette.border
                    .frame(width: 1)
                Text(reasoning)
                    .font(.system(size: max(11, model.settings.fontSize - 2)))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
                if isGenerating && !isExpanded {
                    AssistantActivityView(text: "Thinking…")
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: isGenerating && !isExpanded)
        }
        .padding(.vertical, 2)
    }
}