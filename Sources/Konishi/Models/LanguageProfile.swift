import Foundation

/// Common European Framework level, a coarse self-rated anchor. Used mainly at cold start
/// (empty deck); the deck's contents and accuracy are the primary difficulty signal over time.
enum CEFRLevel: String, Codable, CaseIterable, Sendable, Identifiable {
    case a1, a2, b1, b2, c1, c2

    var id: String { rawValue }
    /// Standard code shown to the model, e.g. "A2".
    var code: String { rawValue.uppercased() }
    var label: String {
        switch self {
        case .a1: "Beginner (A1)"
        case .a2: "Elementary (A2)"
        case .b1: "Intermediate (B1)"
        case .b2: "Upper-Intermediate (B2)"
        case .c1: "Advanced (C1)"
        case .c2: "Fluent (C2)"
        }
    }
}

/// Whether the model should show romanization/pronunciation alongside the native script.
/// Essential for some languages (pinyin for Chinese), unwanted for others (Hangul reads fine).
enum RomanizationMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case always
    case whenNew
    case never

    var id: String { rawValue }
    var label: String {
        switch self {
        case .always: "Always show"
        case .whenNew: "Only for new words"
        case .never: "Never (native script only)"
        }
    }

    /// Instruction injected into the system prompt.
    var guidance: String {
        switch self {
        case .always: "Always include romanization (e.g. pinyin) alongside the native script."
        case .whenNew: "Include romanization only when introducing a new word or after I answer one wrong; otherwise use the native script alone."
        case .never: "Never add romanization — use the native script only. I can read it."
        }
    }
}

/// A language-learning configuration: the target language, the language explanations are given in,
/// the learner's level, and script/goal preferences. Designed to allow multiple profiles later;
/// v1 keeps a single active profile (AppSettings.activeLanguageProfileID).
struct LanguageProfile: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    /// BCP-47 / locale identifier used for STT + TTS, e.g. "ko-KR".
    var targetLocale: String
    /// Human-readable target language, e.g. "Korean".
    var targetName: String
    /// Locale for explanations / the learner's native language, e.g. "en-US".
    var baseLocale: String
    var baseName: String
    /// Coarse self-rated level; cold-start anchor and default session difficulty.
    var level: CEFRLevel
    /// Whether to show romanization/pronunciation.
    var romanization: RomanizationMode
    /// Free-text script guidance, e.g. "simplified characters", "furigana over kanji".
    var scriptNotes: String
    /// Chosen TTS voice identifier for the target language ("" = automatic best).
    var targetVoiceID: String
    /// Chosen TTS voice identifier for the explanation language ("" = automatic best).
    var baseVoiceID: String
    /// Free-text learning goals shown to the model.
    var goals: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        targetLocale: String,
        targetName: String,
        baseLocale: String = "en-US",
        baseName: String = "English",
        level: CEFRLevel = .a1,
        romanization: RomanizationMode = .whenNew,
        scriptNotes: String = "",
        targetVoiceID: String = "",
        baseVoiceID: String = "",
        goals: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.targetLocale = targetLocale
        self.targetName = targetName
        self.baseLocale = baseLocale
        self.baseName = baseName
        self.level = level
        self.romanization = romanization
        self.scriptNotes = scriptNotes
        self.targetVoiceID = targetVoiceID
        self.baseVoiceID = baseVoiceID
        self.goals = goals
        self.createdAt = createdAt
    }

    /// Curated (display name, locale) pairs for the profile editor. Locales feed STT/TTS.
    static let commonLanguages: [(name: String, locale: String)] = [
        ("English", "en-US"), ("Spanish", "es-ES"), ("French", "fr-FR"),
        ("German", "de-DE"), ("Italian", "it-IT"), ("Portuguese", "pt-BR"),
        ("Korean", "ko-KR"), ("Japanese", "ja-JP"), ("Mandarin Chinese", "zh-CN"),
        ("Cantonese", "zh-HK"), ("Russian", "ru-RU"), ("Arabic", "ar-SA"),
        ("Hindi", "hi-IN"), ("Dutch", "nl-NL"), ("Swedish", "sv-SE"),
        ("Turkish", "tr-TR"), ("Polish", "pl-PL"), ("Vietnamese", "vi-VN"),
        ("Thai", "th-TH"), ("Indonesian", "id-ID"), ("Greek", "el-GR"),
        ("Hebrew", "he-IL"), ("Ukrainian", "uk-UA"), ("Czech", "cs-CZ"),
        ("Danish", "da-DK"), ("Finnish", "fi-FI"), ("Norwegian", "nb-NO"),
        ("Romanian", "ro-RO"), ("Hungarian", "hu-HU")
    ]
}
