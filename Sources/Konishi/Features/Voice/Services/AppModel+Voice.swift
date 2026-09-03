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

    var nativeTTS: Bool { mode == .language || settings.ttsSource == .native }

    /// Speaks newly-completed sentences as the reply streams in (native and server TTS), so speech
    /// starts almost immediately instead of waiting for the whole message. Only the unspoken tail
    /// is scanned (via `ttsPending`), not the whole growing message.
    func streamSpeak(delta: String, assistantID: UUID) {
        guard settings.autoSpeak else { return }
        if ttsMessageID != assistantID {
            ttsMessageID = assistantID
            ttsPending = ""
        }
        ttsPending += delta
        guard let cut = ttsPending.lastIndex(where: { Self.sentenceTerminators.contains($0) })
        else { return }
        let chunk = String(ttsPending[...cut])
        ttsPending = String(ttsPending[ttsPending.index(after: cut)...])
        enqueueSpeech(chunk)
    }

    /// At end of stream: speak whatever sentence tail wasn't already streamed. Works for both
    /// native and server TTS (server sentences flow through the same serial synth pipeline).
    func emitFinalSpeech(assistantID: UUID, content: String) {
        guard settings.autoSpeak else { return }
        // If streaming never accumulated this message (e.g. auto-speak toggled on late), speak it whole.
        if ttsMessageID != assistantID {
            ttsMessageID = assistantID
            ttsPending = content
        }
        let tail = ttsPending
        ttsPending = ""
        guard !tail.isEmpty else { return }
        enqueueSpeech(tail)
    }

    private func enqueueSpeech(_ text: String) {
        let clean = text.strippedForSpeech
        guard !clean.isEmpty else { return }
        if mode == .language, let p = activeLanguageProfile {
            voice.enqueueBilingual(
                clean, targetLocale: p.targetLocale, baseLocale: p.baseLocale,
                targetVoiceID: p.targetVoiceID, baseVoiceID: p.baseVoiceID,
                rate: settings.speechRate)
        } else if nativeTTS {
            voice.enqueueNative(clean, voiceID: settings.voiceIdentifier, rate: settings.speechRate)
        } else {
            beginServerSpeechIfNeeded()
            speechSegCont?.yield(clean)
        }
    }

    /// Lazily starts the serial server-TTS pipeline for the current reply: each sentence is
    /// synthesized in order and its audio queued for gapless playback.
    private func beginServerSpeechIfNeeded() {
        guard speechSegCont == nil else { return }
        voice.startOutputKeepAlive()  // keep the device warm so the first sentence isn't clipped
        voice.beginAudioStream()
        let ttsConfig = settings.requestConfig(modelOverride: nil)
        let (segs, cont) = AsyncStream.makeStream(of: String.self)
        speechSegCont = cont
        speechSynthTask = Task { [weak self] in
            for await seg in segs {
                guard let self else { break }
                do {
                    let data = try await ChatService.speech(config: ttsConfig, text: seg)
                    self.warnedServerTTSFailure = false
                    self.voice.enqueueAudioData(data)
                } catch {
                    self.warnServerTTSFailure(error)
                    break  // audio endpoint unreachable — stop hammering it
                }
            }
            self?.voice.sealAudioStream()
        }
    }

    /// Stops any current speech and resets streaming-TTS progress for a fresh reply.
    func resetSpeech() {
        voice.stopSpeaking()
        speechSegCont?.finish()
        speechSegCont = nil
        speechSynthTask?.cancel()
        speechSynthTask = nil
        if !conversationActive { voice.stopOutputKeepAlive() }
        ttsMessageID = nil
        ttsPending = ""
    }

    /// Surfaces a server-TTS failure only the first time this session; afterwards it stays silent
    /// (audio is just skipped) so the banner doesn't reappear on every reply once you've seen it.
    func warnServerTTSFailure(_ error: Error) {
        guard !warnedServerTTSFailure else { return }
        warnedServerTTSFailure = true
        voice.lastError =
            "Server TTS unavailable — replies won't be spoken this session. \(error.localizedDescription)"
    }
}
