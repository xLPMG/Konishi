import SwiftUI

/// Interactive multiple-choice prompt for the `ask_multiple_choice` tool. Shows one question at
/// a time; selecting an option advances, and the last answer resumes the paused turn.
struct MultipleChoiceView: View {
    @Environment(AppModel.self) private var model
    let interaction: PendingInteraction
    @State private var current = 0
    @State private var choices: [Int]

    init(interaction: PendingInteraction) {
        self.interaction = interaction
        _choices = State(initialValue: Array(repeating: -1, count: interaction.questions.count))
    }

    var body: some View {
        let q = interaction.questions[current]
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Question \(current + 1) of \(interaction.questions.count)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Skip") { advance(choice: -1) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Text(q.prompt).font(.title3.weight(.semibold))
            ForEach(Array(q.options.enumerated()), id: \.offset) { idx, opt in
                Button { advance(choice: idx) } label: {
                    HStack {
                        Text(opt).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 10).padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 460, height: 360)
        .interactiveDismissDisabled(true)
    }

    private func advance(choice: Int) {
        choices[current] = choice
        if current + 1 < interaction.questions.count {
            current += 1
        } else {
            model.submitInteraction(choices)
        }
    }
}
