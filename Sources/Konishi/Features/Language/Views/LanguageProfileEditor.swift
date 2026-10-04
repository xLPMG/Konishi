import SwiftUI
import AVFoundation

/// Create or edit a language-learning profile (target/base language, level, romanization, notes).
struct LanguageProfileEditor: View {
    @Environment(AppModel.self) private var model
       @Environment(LanguageWorkspaceModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LanguageProfile
    private let isNew: Bool

    init(profile: LanguageProfile?) {
        self.isNew = profile == nil
        _draft = State(initialValue: profile ?? LanguageProfile(targetLocale: "ko-KR", targetName: "Korean"))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    languagePicker("I'm learning", locale: $draft.targetLocale, name: $draft.targetName)
                    languagePicker("Explained in", locale: $draft.baseLocale, name: $draft.baseName)
                } header: {
                    Text("Languages")
                } footer: {
                    if draft.targetLocale == draft.baseLocale {
                        Text("Target and explanation language must differ.")
                            .foregroundStyle(.orange)
                    }
                }
                Section("Level") {
                    Picker("Level", selection: $draft.level) {
                        ForEach(CEFRLevel.allCases) { Text($0.label).tag($0) }
                    }
                }
                Section("Script") {
                    Picker("Romanization", selection: $draft.romanization) {
                        ForEach(RomanizationMode.allCases) { Text($0.label).tag($0) }
                    }
                    TextField("Script notes (e.g. simplified characters, furigana)", text: $draft.scriptNotes)
                }
                Section {
                    voicePicker("Target voice", locale: draft.targetLocale, selection: $draft.targetVoiceID)
                    voicePicker("Explanation voice", locale: draft.baseLocale, selection: $draft.baseVoiceID)
                } header: {
                    Text("Voices")
                } footer: {
                    Text("Install more voices in System Settings › Accessibility › Spoken Content › Manage Voices.")
                }
                Section("Goals") {
                    TextField("What do you want to achieve?", text: $draft.goals, axis: .vertical)
                        .lineLimit(2...5)
                }
                if !isNew {
                    Section {
                        Button(role: .destructive) {
                               workspace.deleteProfile(draft.id)
                            dismiss()
                        } label: {
                            Label("Delete Language", systemImage: "trash")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .themedFormBackground(model.currentPalette.canvas)
            .navigationTitle(isNew ? "New Language" : "Edit Language")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                           workspace.saveProfile(draft, makeActive: true)
                        dismiss()
                    }
                    .disabled(draft.targetName.isEmpty || draft.targetLocale == draft.baseLocale)
                }
            }
        }
        .frame(width: 460, height: 480)
    }

    private func languagePicker(_ title: String, locale: Binding<String>, name: Binding<String>) -> some View {
        Picker(title, selection: locale) {
            ForEach(LanguageProfile.commonLanguages, id: \.locale) { lang in
                Text(lang.name).tag(lang.locale)
            }
        }
        .onChange(of: locale.wrappedValue) { _, newLocale in
            if let match = LanguageProfile.commonLanguages.first(where: { $0.locale == newLocale }) {
                name.wrappedValue = match.name
            }
        }
    }

    private func voicePicker(_ title: String, locale: String, selection: Binding<String>) -> some View {
        let voices = VoiceManager.installedVoices(forLocale: locale)
        return Picker(title, selection: selection) {
            Text("Automatic (best)").tag("")
            ForEach(voices, id: \.identifier) { v in
                Text(Self.voiceLabel(v)).tag(v.identifier)
            }
        }
        .disabled(voices.isEmpty)
    }

    private static func voiceLabel(_ v: AVSpeechSynthesisVoice) -> String {
        let lower = v.name.lowercased()
        if lower.contains("(premium)") || lower.contains("(enhanced)") { return v.name }
        switch v.quality {
        case .premium: return v.name + " (Premium)"
        case .enhanced: return v.name + " (Enhanced)"
        default: return v.name
        }
    }
}
