import Foundation

extension AppModel {
    func speak(_ text: String) {
        let clean = text.strippedForSpeech
        guard !clean.isEmpty else { return }
        voice.lastError = nil
        // Language practice: native voices switch per language; server TTS can't do the target language well.
        if mode == .language, let p = activeLanguageProfile {
            voice.speakBilingual(
                clean, targetLocale: p.targetLocale, baseLocale: p.baseLocale,
                targetVoiceID: p.targetVoiceID, baseVoiceID: p.baseVoiceID,
                rate: settings.speechRate)
            return
        }
        if settings.ttsSource == .server {
            let config = settings.requestConfig(modelOverride: nil)
            Task { [weak self] in
                guard let self else { return }
                do {
                    let data = try await ChatService.speech(config: config, text: clean)
                    self.voice.playAudioData(data)
                } catch {
                    self.voice.lastError = "Server TTS failed: \(error.localizedDescription)"
                }
            }
        } else {
            voice.speakNative(clean, voiceID: settings.voiceIdentifier, rate: settings.speechRate)
        }
    }

    func toggleDictation() {
        if voice.isListening {
            if settings.sttSource == .server {
                let config = settings.requestConfig(modelOverride: nil)
                Task { [weak self] in
                    guard let self else { return }
                    if let text = await self.voice.stopRecordingAndTranscribe(config: config) {
                        self.draft = self.draft.isEmpty ? text : self.draft + " " + text
                    }
                }
            } else {
                voice.stopDictation()
            }
        } else {
            if settings.sttSource == .server {
                voice.startRecording()
            } else {
                voice.startNativeDictation(locale: languageDictationLocale()) {
                    [weak self] update in
                    self?.draft = update.text
                }
            }
        }
    }

    /// Locale for native dictation: the chosen practice language in Learn mode, else English.
    func languageDictationLocale() -> String {
        guard mode == .language, let p = activeLanguageProfile else { return "en-US" }
        return languageInputTarget ? p.targetLocale : p.baseLocale
    }
}
