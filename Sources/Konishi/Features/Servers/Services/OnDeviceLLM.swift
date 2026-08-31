#if canImport(FoundationModels)
import FoundationModels
#endif
import Foundation

/// Thin wrapper over Apple's on-device model (FoundationModels). Used for cheap auxiliary
/// tasks (summaries, reflection, diff review) so they run on the ANE instead of the GPU
/// server. Everything degrades to nil when the model is unavailable, so callers fall back.
enum OnDeviceLLM {
    #if canImport(FoundationModels)
    @Generable
    struct BackchannelDecision {
        @Guide(description: "True only for a brief listener acknowledgement like mm-hm, yeah, right, or I see that does not take the conversational floor. False for a question, correction, command, disagreement, new information, or uncertainty.")
        var isBackchannel: Bool
    }

    @MainActor private static var backchannelSession: LanguageModelSession?
    @MainActor private static var backchannelClassifierEnabled = false

    @MainActor private static func makeBackchannelSession() -> LanguageModelSession {
        LanguageModelSession(instructions: "Classify quoted speech heard while an assistant is talking. Be conservative: uncertain speech is an interruption.")
    }
    #endif

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    /// Human-readable availability for the settings UI.
    static var status: String {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            return "Available — runs on the Neural Engine"
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Unavailable — enable Apple Intelligence in System Settings"
        case .unavailable(.deviceNotEligible):
            return "Unavailable — this device isn't eligible"
        case .unavailable(.modelNotReady):
            return "Preparing… the model is still downloading"
        case .unavailable:
            return "Unavailable"
        }
        #else
        return "Unavailable — requires the macOS 26 SDK"
        #endif
    }

    /// One-shot completion on the on-device model, or nil if unavailable / it fails.
    static func complete(prompt: String, temperature: Double? = nil) async -> String? {
        #if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: temperature))
            return response.content
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Enables the dedicated classifier and prepares its first one-use session.
    @MainActor static func startBackchannelClassifier() {
        backchannelClassifierEnabled = true
        prepareBackchannelClassifier()
    }

    /// Releases Konishi's retained session. Apple's shared inference service may remain cached by
    /// macOS after this, but Konishi no longer keeps a classifier session alive.
    @MainActor static func stopBackchannelClassifier() {
        backchannelClassifierEnabled = false
        backchannelSession = nil
    }

    /// Prepares a fresh dedicated classifier before an interruption occurs. Each session is used
    /// once so prior classifications cannot contaminate later decisions.
    @MainActor private static func prepareBackchannelClassifier() {
        #if canImport(FoundationModels)
        guard backchannelClassifierEnabled,
              case .available = SystemLanguageModel.default.availability,
              backchannelSession == nil else { return }
        let session = makeBackchannelSession()
        session.prewarm()
        backchannelSession = session
        #endif
    }

    /// Returns nil on unavailability, refusal, or any generation error so callers can conservatively
    /// treat the speech as an interruption.
    @MainActor static func classifyBackchannel(_ speech: String) async -> Bool? {
        #if canImport(FoundationModels)
        guard backchannelClassifierEnabled,
              case .available = SystemLanguageModel.default.availability else { return nil }
        let session = backchannelSession ?? makeBackchannelSession()
        backchannelSession = nil
        defer { prepareBackchannelClassifier() }
        do {
            let response = try await session.respond(
                to: "Speech: \"\(speech)\"",
                generating: BackchannelDecision.self,
                options: GenerationOptions(temperature: 0)
            )
            return response.content.isBackchannel
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }
}
