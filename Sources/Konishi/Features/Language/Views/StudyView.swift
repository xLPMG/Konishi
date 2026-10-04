import SwiftUI

struct StudyView: View {
    @Environment(AppModel.self) private var appModel
    @Bindable var workspace: LanguageWorkspaceModel
    @State private var topic = ""

    init(workspace: LanguageWorkspaceModel, initialTopic: String = "") {
        _workspace = Bindable(wrappedValue: workspace)
        _topic = State(initialValue: initialTopic)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Study").font(.largeTitle.weight(.semibold))
                    Text("Create vocabulary candidates for \(workspace.activeProfile?.targetName ?? "your language").")
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    themedField("Topic or situation", text: $topic)
                        .onSubmit(generate)
                    Button(action: generate) {
                        if workspace.isGeneratingProposals {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(workspace.studyProposals.isEmpty ? "Generate" : "Generate More", systemImage: "sparkles")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(workspace.activeProfile == nil || workspace.isGeneratingProposals)
                }

                if let error = workspace.proposalError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red).textSelection(.enabled)
                }

                if !workspace.studyProposals.isEmpty {
                    Text("Vocabulary proposals").font(.headline).padding(.top, 4)
                    ForEach($workspace.studyProposals) { $proposal in
                        proposalEditor($proposal)
                        if proposal.id != workspace.studyProposals.last?.id { Divider() }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(appModel.currentPalette.canvas.ignoresSafeArea())
        .onAppear { workspace.proposalTopic = "" }
    }

    private func proposalEditor(_ proposal: Binding<VocabularyProposal>) -> some View {
        let duplicate = workspace.isDuplicateProposal(proposal.wrappedValue)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                themedField("Target term", text: proposal.targetTerm)
                    .font(.title3.weight(.medium))
                themedField("Reading", text: proposal.reading)
                    .frame(maxWidth: 180)
            }
            themedField("Translation", text: proposal.translation)
            themedField("Alternative translations, one per line", text: Binding(
                get: { proposal.wrappedValue.acceptedTranslations.joined(separator: "\n") },
                set: { proposal.wrappedValue.acceptedTranslations = $0.split(whereSeparator: \.isNewline).map(String.init) }),
                axis: .vertical)
                .lineLimit(2...4)
            HStack(spacing: 10) {
                themedField("Part of speech", text: proposal.partOfSpeech)
                themedField("Register", text: proposal.register)
            }
            themedField("Example", text: proposal.example)
            themedField("Notes", text: proposal.notes)
            themedField("Tags, separated by commas", text: Binding(
                get: { proposal.wrappedValue.tags.joined(separator: ", ") },
                set: { proposal.wrappedValue.tags = $0.split(separator: ",").map(String.init) }))

            if duplicate {
                Label("This term already exists in the active deck.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Skip") { workspace.skipProposal(proposal.wrappedValue.id) }
                    .buttonStyle(.bordered)
                Button {
                    workspace.saveProposal(proposal.wrappedValue)
                } label: {
                    Label("Save to Deck", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(duplicate || proposal.wrappedValue.normalized() == nil)
            }
        }
        .padding(.vertical, 12)
    }

    private func generate() {
        let config = appModel.settings.requestConfig(modelOverride: nil)
        workspace.generateProposals(config: config, topic: topic.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func themedField(_ title: String, text: Binding<String>, axis: Axis = .horizontal) -> some View {
        TextField(title, text: text, axis: axis)
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(appModel.currentPalette.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(appModel.currentPalette.border, lineWidth: 1))
            .tint(appModel.currentPalette.signal)
    }
}