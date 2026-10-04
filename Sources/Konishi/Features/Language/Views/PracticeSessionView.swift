import SwiftUI

struct PracticeSessionView: View {
    @Bindable var workspace: LanguageWorkspaceModel
    @State private var selectedChoiceID: UUID?
    @State private var answerText = ""
    @State private var selectedTermID: UUID?
    @State private var selectedMeaningID: UUID?
    @State private var matches: [LanguageMatch] = []

    private var question: LanguageQuestion? { workspace.practiceSession?.currentQuestion }

    var body: some View {
        Group {
            if let session = workspace.practiceSession, session.isComplete {
                completion(session)
            } else if let session = workspace.practiceSession, let question {
                exercise(session: session, question: question)
            } else {
                ContentUnavailableView("No Active Review", systemImage: "checkmark.circle")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: workspace.practiceSession?.currentQuestion?.id) { clearAnswer() }
    }

    private func exercise(session: LanguagePracticeSession, question: LanguageQuestion) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    workspace.cancelPractice()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("End this review")
                Spacer()
                Text("\(question.activity.label) · \(session.currentIndex + 1) of \(session.questions.count)")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button("Skip") { workspace.skipQuestion() }
                    .disabled(!workspace.canSkipCurrentQuestion)
            }
            .padding(.horizontal, 22).padding(.vertical, 14)

            ProgressView(value: Double(session.currentIndex), total: Double(max(1, session.questions.count)))
                .padding(.horizontal, 22)

            Spacer(minLength: 20)
            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    Text(question.prompt)
                        .font(.title2.weight(.medium))
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .frame(maxWidth: 620)
                    if question.activity == .flashcards && workspace.isFlashcardRevealed {
                        Text(question.answer)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                    }
                }
                .frame(minHeight: 112)

                answerControls(question)
                    .frame(maxWidth: 620)

                if let error = workspace.reviewError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                        .frame(maxWidth: 620, alignment: .leading)
                }

                if workspace.answerRecorded {
                    savedResult(question)
                        .frame(maxWidth: 620, alignment: .leading)
                }
            }
            .padding(.horizontal, 24)
            Spacer(minLength: 24)
        }
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func answerControls(_ question: LanguageQuestion) -> some View {
        switch question.activity {
        case .flashcards:
            if workspace.isFlashcardRevealed {
                HStack(spacing: 12) {
                    Button("Again") { workspace.submitAnswer(.selfRating(remembered: false)) }
                        .buttonStyle(.bordered)
                        .disabled(workspace.answerRecorded)
                    Button("Remembered") { workspace.submitAnswer(.selfRating(remembered: true)) }
                        .buttonStyle(.borderedProminent)
                        .disabled(workspace.answerRecorded)
                }
            } else {
                Button("Reveal answer") { workspace.revealFlashcard() }
                    .buttonStyle(.borderedProminent)
            }
        case .multipleChoice:
            VStack(spacing: 8) {
                ForEach(question.choices) { choice in
                    Button {
                        selectedChoiceID = choice.id
                    } label: {
                        HStack {
                            Text(choice.text).frame(maxWidth: .infinity, alignment: .leading)
                            if selectedChoiceID == choice.id { Image(systemName: "checkmark.circle.fill") }
                        }
                        .padding(.horizontal, 12).frame(minHeight: 42)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .tint(selectedChoiceID == choice.id ? .accentColor : .secondary)
                    .disabled(workspace.answerRecorded)
                }
                Button("Check answer") {
                    if let selectedChoiceID { workspace.submitAnswer(.choice(selectedChoiceID)) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedChoiceID == nil || workspace.answerRecorded)
                .padding(.top, 6)
            }
        case .typedRecall, .cloze:
            VStack(spacing: 12) {
                TextField("Your answer", text: $answerText)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .onSubmit { submitText() }
                    .disabled(workspace.answerRecorded)
                Button("Check answer", action: submitText)
                    .buttonStyle(.borderedProminent)
                    .disabled(answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workspace.answerRecorded)
            }
        case .matching:
            matchingControls(question)
        }
    }

    private func matchingControls(_ question: LanguageQuestion) -> some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                optionColumn(title: "Terms", options: question.matchTerms, selectedID: selectedTermID) { id in
                    selectedTermID = id
                    makeMatchIfReady()
                }
                optionColumn(title: "Meanings", options: question.matchMeanings, selectedID: selectedMeaningID) { id in
                    selectedMeaningID = id
                    makeMatchIfReady()
                }
            }
            if !matches.isEmpty {
                Text("\(matches.count) of \(question.itemIDs.count) pairs selected")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Check matches") {
                workspace.submitAnswer(.matches(matches))
            }
            .buttonStyle(.borderedProminent)
            .disabled(matches.count != question.itemIDs.count || workspace.answerRecorded)
        }
    }

    private func optionColumn(
        title: String, options: [LanguageOption], selectedID: UUID?, select: @escaping (UUID) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(options) { option in
                let isMatched = matches.contains {
                    title == "Terms" ? $0.termOptionID == option.id : $0.meaningOptionID == option.id
                }
                Button { select(option.id) } label: {
                    Text(option.text)
                        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                        .padding(.horizontal, 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .tint(selectedID == option.id ? .accentColor : .secondary)
                .disabled(isMatched || workspace.answerRecorded)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func savedResult(_ question: LanguageQuestion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: resultSymbol(question))
                    .foregroundStyle(resultColor(question))
                Text(resultTitle(question)).font(.headline)
                Spacer()
            }
            if question.activity == .matching {
                Text("\(workspace.recordedCorrectCount) of \(workspace.recordedAttemptCount) pairs correct")
                    .font(.callout).foregroundStyle(.secondary)
            } else if question.activity != .flashcards && !workspace.answerResult!.allCorrect {
                Text("Expected: \(question.answer)")
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Button("Continue") { workspace.continuePractice() }
                .buttonStyle(.borderedProminent)
        }
        .padding(.top, 8)
    }

    private func completion(_ session: LanguagePracticeSession) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 42)).foregroundStyle(.green)
            Text("Review complete").font(.title2.weight(.semibold))
            Text("\(session.completedCount) activities · \(session.outcomes.count) cards recorded")
                .foregroundStyle(.secondary)
            HStack {
                Button("Review again") { workspace.cancelPractice() }
                    .buttonStyle(.bordered)
                Button("Learn home") { workspace.cancelPractice(); workspace.destination = .home }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultSymbol(_ question: LanguageQuestion) -> String {
        if question.activity == .flashcards { return "checkmark.circle.fill" }
        return workspace.answerResult?.allCorrect == true ? "checkmark.circle.fill" : "arrow.counterclockwise.circle.fill"
    }

    private func resultColor(_ question: LanguageQuestion) -> Color {
        if question.activity == .flashcards { return .green }
        return workspace.answerResult?.allCorrect == true ? .green : .orange
    }

    private func resultTitle(_ question: LanguageQuestion) -> String {
        if question.activity == .flashcards { return "Self-rating saved" }
        return workspace.answerResult?.allCorrect == true ? "Correct" : "Review saved" 
    }

    private func submitText() {
        guard workspace.practiceSession?.currentQuestion != nil else { return }
        workspace.submitAnswer(.text(answerText))
    }

    private func makeMatchIfReady() {
        guard let term = selectedTermID, let meaning = selectedMeaningID,
              !matches.contains(where: { $0.termOptionID == term || $0.meaningOptionID == meaning })
        else { return }
        matches.append(LanguageMatch(termOptionID: term, meaningOptionID: meaning))
        selectedTermID = nil
        selectedMeaningID = nil
    }

    private func clearAnswer() {
        selectedChoiceID = nil
        answerText = ""
        selectedTermID = nil
        selectedMeaningID = nil
        matches = []
    }
}