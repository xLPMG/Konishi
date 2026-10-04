import SwiftUI

private struct ProfileEditorTarget: Identifiable {
    let id = UUID()
    let profile: LanguageProfile?
}

enum LanguageProgressTimeFormatter {
    static func text(for date: Date, now: Date = Date()) -> String {
        let elapsed = max(0, now.timeIntervalSince(date))
        if elapsed < 60 { return "Just now" }

        let amount: Int
        let unit: String
        if elapsed < 60 * 60 {
            amount = Int(elapsed / 60)
            unit = amount == 1 ? "minute" : "minutes"
        } else if elapsed < 24 * 60 * 60 {
            amount = Int(elapsed / (60 * 60))
            unit = amount == 1 ? "hour" : "hours"
        } else {
            amount = Int(elapsed / (24 * 60 * 60))
            unit = amount == 1 ? "day" : "days"
        }
        return "\(amount) \(unit) ago"
    }
}

struct LanguageSidebarView: View {
    @Environment(AppModel.self) private var appModel
    let workspace: LanguageWorkspaceModel

    private var primary: [LanguageWorkspaceDestination] {
        var destinations: [LanguageWorkspaceDestination] = [.home, .practice, .study, .deck, .tutor]
        if workspace.practiceSession != nil {
            destinations.insert(.session, at: 2)
        }
        return destinations
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "character.book.closed.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(appModel.currentAccent)
                    .frame(width: 36, height: 36)
                    .background(appModel.currentPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Learn").font(.headline)
                    Text(workspace.activeProfile?.targetName.uppercased() ?? "LANGUAGE WORKSPACE")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(14)

            List {
                Section("Learn") {
                    ForEach(primary) { destination in navigationRow(destination) }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(appModel.currentPalette.sidebar.ignoresSafeArea())
        .overlay(alignment: .trailing) { appModel.currentPalette.border.frame(width: 1) }
    }

    private func navigationRow(_ destination: LanguageWorkspaceDestination) -> some View {
        Button { workspace.destination = destination } label: {
            Label(destination.label, systemImage: destination.icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 7)
                .fill(workspace.destination == destination ? appModel.currentPalette.surfaceRaised : .clear))
    }
}

struct LanguageWorkspaceView: View {
    @Environment(AppModel.self) private var appModel
    let workspace: LanguageWorkspaceModel
    @State private var editorTarget: ProfileEditorTarget?

    var body: some View {
        Group {
            switch workspace.destination {
            case .home:
                LanguageHomeView(workspace: workspace) { editorTarget = ProfileEditorTarget(profile: $0) }
            case .practice:
                PracticeSetupView(workspace: workspace)
            case .session:
                PracticeSessionView(workspace: workspace)
            case .study:
                StudyView(workspace: workspace, initialTopic: workspace.proposalTopic)
            case .deck:
                DeckView().environment(workspace)
            case .tutor:
                TutorConversationView(workspace: workspace)
            }
        }
        .environment(workspace)
        .sheet(item: $editorTarget) { target in
            LanguageProfileEditor(profile: target.profile)
                .environment(workspace)
                .environment(appModel)
        }
        .onAppear { workspace.refresh() }
    }
}

private struct LanguageHomeView: View {
    @Environment(AppModel.self) private var appModel
    let workspace: LanguageWorkspaceModel
    let editProfile: (LanguageProfile?) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Learn").font(.largeTitle.weight(.semibold))
                        Text(workspace.activeProfile.map { "\($0.targetName) · \($0.level.code)" } ?? "Set up a language profile")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    profileMenu
                }

                if let profile = workspace.activeProfile {
                    overview(profile: profile)
                    activityEntries
                    recentProgress(profileID: profile.id)
                } else {
                    ContentUnavailableView {
                        Label("Start Learning", systemImage: "character.book.closed")
                    } description: {
                        Text("Create a language profile to start a deck and track your progress.")
                    } actions: {
                        Button("Set Up a Language") { editProfile(nil) }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var profileMenu: some View {
        Menu {
            ForEach(workspace.profiles) { profile in
                Button {
                    workspace.selectProfile(profile.id)
                } label: {
                    if workspace.activeProfile?.id == profile.id {
                        Label("\(profile.targetName) · \(profile.level.code)", systemImage: "checkmark")
                    } else {
                        Text("\(profile.targetName) · \(profile.level.code)")
                    }
                }
            }
            Divider()
            Button("New Language…") { editProfile(nil) }
            if let profile = workspace.activeProfile {
                Button("Edit \(profile.targetName)…") { editProfile(profile) }
            }
        } label: {
            Label("Profiles", systemImage: "person.crop.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func overview(profile: LanguageProfile) -> some View {
        let stats = workspace.activeStats
        return HStack(spacing: 0) {
            metric("Due", value: stats.due, icon: "clock", tint: .orange)
            Divider().padding(.vertical, 6)
            metric("Reviewed today", value: stats.reviewedToday, icon: "checkmark.circle", tint: .green)
            Divider().padding(.vertical, 6)
            metric("Mastered", value: stats.mastered, icon: "star", tint: appModel.currentAccent)
            Spacer(minLength: 0)
            Text("\(stats.total) cards").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.vertical, 14)
        .overlay(alignment: .top) { appModel.currentPalette.border.frame(height: 1) }
        .overlay(alignment: .bottom) { appModel.currentPalette.border.frame(height: 1) }
        .accessibilityElement(children: .combine)
        .help("Progress for \(profile.targetName)")
    }

    private func metric(_ title: String, value: Int, icon: String, tint: Color) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(value)").font(.title3.weight(.semibold).monospacedDigit())
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 130, alignment: .leading)
    }

    private var activityEntries: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Activities").font(.headline).padding(.bottom, 8)
            activityRow(.practice, detail: "Flashcards, multiple choice, matching and recall")
            Divider().padding(.leading, 34)
            activityRow(.study, detail: "Create a lesson from reviewed vocabulary proposals")
            Divider().padding(.leading, 34)
            activityRow(.deck, detail: "Browse and manage saved vocabulary")
            Divider().padding(.leading, 34)
            activityRow(.tutor, detail: "Practice conversation in a separate tutor thread")
        }
    }

    private func activityRow(_ destination: LanguageWorkspaceDestination, detail: String) -> some View {
        Button { workspace.destination = destination } label: {
            HStack(spacing: 12) {
                Image(systemName: destination.icon)
                    .font(.system(size: 15, weight: .medium)).frame(width: 24)
                    .foregroundStyle(appModel.currentAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(destination.label).font(.body.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle()).padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    private func recentProgress(profileID: UUID) -> some View {
        let attempts = workspace.store.reviewAttempts(profileID: profileID, limit: 5)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Recent progress").font(.headline)
            if attempts.isEmpty {
                Text("No reviews yet").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(attempts) { attempt in
                    HStack(spacing: 10) {
                        Image(systemName: attempt.outcome.isCorrect ? "checkmark.circle.fill" : "arrow.counterclockwise.circle.fill")
                            .foregroundStyle(attempt.outcome.isCorrect ? .green : .orange)
                        Text(workspace.store.item(id: attempt.itemID)?.term ?? "Removed card").font(.callout)
                        Spacer()
                        Text(attempt.activity.label).font(.caption).foregroundStyle(.secondary)
                        Text(LanguageProgressTimeFormatter.text(for: attempt.createdAt))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

}