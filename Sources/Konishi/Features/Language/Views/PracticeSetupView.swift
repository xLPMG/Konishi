import SwiftUI

struct PracticeSetupView: View {
    @Environment(AppModel.self) private var appModel
    @Bindable var workspace: LanguageWorkspaceModel

    private var countRange: ClosedRange<Int> {
        workspace.selectedActivity == .matching ? 2...4 : 1...30
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review").font(.largeTitle.weight(.semibold))
                    Text("Due cards are selected from \(workspace.activeProfile?.targetName ?? "the active deck").")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Activity").foregroundStyle(.secondary)
                        Spacer()
                        Picker("Activity", selection: $workspace.selectedActivity) {
                            ForEach(LanguageActivity.allCases) { activity in
                                Label(activity.label, systemImage: activity.icon).tag(activity)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    Divider().overlay(appModel.currentPalette.border)
                    HStack {
                        Text("Direction").foregroundStyle(.secondary)
                        Spacer()
                        if workspace.selectedActivity == .mixedReview {
                            Label("Both, randomized", systemImage: "shuffle")
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Direction", selection: $workspace.questionDirection) {
                                ForEach(LanguageQuestionDirection.allCases) { direction in
                                    Text(direction.label).tag(direction)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                        }
                    }
                    Divider().overlay(appModel.currentPalette.border)
                    HStack {
                        Text("Cards per session").foregroundStyle(.secondary)
                        Spacer()
                        Stepper(value: $workspace.sessionLength, in: countRange) {
                            Text("\(workspace.sessionLength)").monospacedDigit()
                        }
                        .accessibilityLabel("Cards per session")
                        .fixedSize()
                    }
                }
                .padding(16)
                .background(appModel.currentPalette.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(appModel.currentPalette.border, lineWidth: 1))
                .tint(appModel.currentPalette.signal)
                .disabled(workspace.canResumePractice)

                if let session = workspace.practiceSession, workspace.canResumePractice {
                    HStack {
                        Label("Paused · \(session.currentIndex + 1) of \(session.questions.count)",
                              systemImage: "pause.circle")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("End Review", role: .destructive) { workspace.cancelPractice() }
                            .buttonStyle(.bordered)
                        Button {
                            workspace.resumePractice()
                        } label: {
                            Label("Resume Review", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    HStack {
                        Label("\(workspace.activeStats.due) due", systemImage: "clock")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            workspace.startPractice()
                        } label: {
                            Label("Start Review", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(workspace.activeProfile == nil)
                    }
                }

                if let error = workspace.reviewError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(appModel.currentPalette.canvas.ignoresSafeArea())
        .onChange(of: workspace.selectedActivity) { _, activity in
            workspace.sessionLength = activity == .matching ? 4 : 10
        }
    }
}