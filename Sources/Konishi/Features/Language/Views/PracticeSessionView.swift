import SwiftUI

private struct AnswerChoiceHover: ViewModifier {
    let enabled: Bool
    @State private var isHovering = false

    func body(content: Content) -> some View {
        let active = enabled && isHovering
        return content
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(active ? 0.12 : 0))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor.opacity(active ? 0.42 : 0), lineWidth: 1)
            }
            .scaleEffect(active ? 1.015 : 1)
            .shadow(color: Color.accentColor.opacity(active ? 0.16 : 0), radius: active ? 6 : 0, y: active ? 2 : 0)
            .onHover { isHovering = enabled && $0 }
            .onChange(of: enabled) { _, isEnabled in
                if !isEnabled { isHovering = false }
            }
            .animation(.easeOut(duration: 0.16), value: active)
    }
}

struct PracticeSessionView: View {
    @Bindable var workspace: LanguageWorkspaceModel
    @State private var selectedChoiceID: UUID?
    @State private var answerText = ""
    @State private var selectedTermID: UUID?
    @State private var selectedMeaningID: UUID?
    @State private var matches: [LanguageMatch] = []

    private var question: LanguageQuestion? { workspace.practiceSession?.currentQuestion }

    private var shouldShowContinue: Bool {
        guard workspace.answerRecorded,
              let question,
              question.activity != .flashcards,
              let isCorrect = workspace.answerResult?.allCorrect
        else { return false }
        return !isCorrect
    }

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
          .task(id: workspace.answerRecorded) {
            guard workspace.answerRecorded, !shouldShowContinue,
                let questionID = workspace.practiceSession?.currentQuestion?.id
            else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled,
                workspace.answerRecorded,
                !shouldShowContinue,
                workspace.practiceSession?.currentQuestion?.id == questionID
            else { return }
            workspace.continuePractice()
          }
    }

    private func exercise(session: LanguagePracticeSession, question: LanguageQuestion) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button("Pause") { workspace.pausePractice() }
                    .buttonStyle(.plain)
                    .help("Pause and return to Review setup")
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

                if workspace.answerRecorded {
                    answerFeedback(question)
                }

                answerControls(question)
                    .frame(maxWidth: 620)

                if shouldShowContinue {
                    Button("Continue") { workspace.continuePractice() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: [])
                }

                if let error = workspace.reviewError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.red).textSelection(.enabled)
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
                        workspace.submitAnswer(.choice(choice.id))
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
                    .modifier(AnswerChoiceHover(enabled: !workspace.answerRecorded))
                    .disabled(workspace.answerRecorded)
                }
                Button("I don't know") {
                    selectedChoiceID = nil
                    workspace.submitAnswer(.dontKnow)
                }
                .buttonStyle(.bordered)
                .disabled(workspace.answerRecorded)
                .padding(.top, 6)
            }
        case .typedRecall, .cloze:
            VStack(spacing: 12) {
                TextField("Your answer", text: $answerText)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .onSubmit { submitText() }
                    .disabled(workspace.answerRecorded)
                HStack(spacing: 10) {
                    Button("Check answer", action: submitText)
                        .buttonStyle(.borderedProminent)
                        .disabled(answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workspace.answerRecorded)
                    Button("I don't know") { workspace.submitAnswer(.dontKnow) }
                        .buttonStyle(.bordered)
                        .disabled(workspace.answerRecorded)
                }
            }
        case .matching:
            matchingControls(question)
        case .mixedReview:
            EmptyView()
        }
    }

    private func matchingControls(_ question: LanguageQuestion) -> some View {
        let termsTitle = question.direction == .targetToBase ? "Terms" : "Meanings"
        let meaningsTitle = question.direction == .targetToBase ? "Meanings" : "Terms"
        return VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                optionColumn(
                    title: termsTitle, options: question.matchTerms, selectedID: selectedTermID, isTermSide: true
                ) { id in
                    selectedTermID = id
                    makeMatchIfReady(for: question)
                }
                optionColumn(
                    title: meaningsTitle, options: question.matchMeanings, selectedID: selectedMeaningID, isTermSide: false
                ) { id in
                    selectedMeaningID = id
                    makeMatchIfReady(for: question)
                }
            }
            if !matches.isEmpty {
                Text("\(matches.count) of \(question.itemIDs.count) pairs selected")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func optionColumn(
        title: String, options: [LanguageOption], selectedID: UUID?, isTermSide: Bool,
        select: @escaping (UUID) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(options) { option in
                let isMatched = matches.contains {
                    isTermSide ? $0.termOptionID == option.id : $0.meaningOptionID == option.id
                }
                Button { select(option.id) } label: {
                    Text(option.text)
                        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                        .padding(.horizontal, 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .tint(selectedID == option.id ? .accentColor : .secondary)
                .modifier(AnswerChoiceHover(enabled: !isMatched && !workspace.answerRecorded))
                .disabled(isMatched || workspace.answerRecorded)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func answerFeedback(_ question: LanguageQuestion) -> some View {
        let isCorrect = workspace.answerResult?.allCorrect == true
        let title = question.activity == .flashcards
            ? "Self-rating saved"
            : isCorrect ? "Correct" : "Not quite"
        let color: Color = question.activity == .flashcards || isCorrect ? .green : .orange
        return VStack(spacing: 6) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(color)
                .accessibilityAddTraits(.updatesFrequently)

            if !isCorrect && question.activity != .flashcards {
                if question.activity == .matching {
                    ForEach(question.correctMatches, id: \.self) { match in
                        if let answer = matchingAnswer(match, question: question) {
                            Text(answer).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("Answer: \(question.answer)")
                        .font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private func matchingAnswer(_ match: LanguageMatch, question: LanguageQuestion) -> String? {
        guard let term = question.matchTerms.first(where: { $0.id == match.termOptionID })?.text,
              let meaning = question.matchMeanings.first(where: { $0.id == match.meaningOptionID })?.text
        else { return nil }
        return "\(term) -> \(meaning)"
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

    private func submitText() {
        guard workspace.practiceSession?.currentQuestion != nil else { return }
        workspace.submitAnswer(.text(answerText))
    }

    private func makeMatchIfReady(for question: LanguageQuestion) {
        guard let term = selectedTermID, let meaning = selectedMeaningID,
              !matches.contains(where: { $0.termOptionID == term || $0.meaningOptionID == meaning })
        else { return }
        let nextMatches = matches + [LanguageMatch(termOptionID: term, meaningOptionID: meaning)]
        matches = nextMatches
        selectedTermID = nil
        selectedMeaningID = nil
        if nextMatches.count == question.itemIDs.count {
            workspace.submitAnswer(.matches(nextMatches))
        }
    }

    private func clearAnswer() {
        selectedChoiceID = nil
        answerText = ""
        selectedTermID = nil
        selectedMeaningID = nil
        matches = []
    }
}