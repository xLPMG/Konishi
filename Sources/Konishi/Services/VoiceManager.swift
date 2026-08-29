import Foundation
import AVFoundation
import Speech
import NaturalLanguage
import Observation

/// Handles native (Apple) and server (OpenAI-compatible) speech: TTS + STT.
@MainActor
@Observable
final class VoiceManager: NSObject, @unchecked Sendable {
    struct DictationUpdate: Sendable {
        let text: String
        let isFinal: Bool
    }

    var isListening = false
    var isSpeaking = false
    var lastError: String?

    /// Invoked when speech finishes naturally (not on manual stop). Used by conversation mode.
    var onFinishSpeaking: (@MainActor () -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    /// Bumped on every new batch/stop; delegate callbacks from a superseded batch are ignored,
    /// so an interrupted utterance's late `didCancel` can't zero out the new batch's state.
    private var speechGeneration = 0
    /// Remaining utterances in the current batch, so `isSpeaking`/`onFinishSpeaking` fire once at the end.
    private var pendingUtterances = 0
    /// Generation each in-flight utterance belongs to, so stale callbacks can be discarded.
    private var utteranceGenerations: [ObjectIdentifier: Int] = [:]
    /// Locale for the next native dictation session (set per prompt for language practice).
    private var dictationLocale = "en-US"

    // Native dictation
    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var onDictationUpdate: ((DictationUpdate) -> Void)?
    private var dictationGeneration = 0

    // Server audio
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var player: AVAudioPlayer?
    /// A silent looping player that keeps the output device (esp. Bluetooth) awake during a
    /// conversation, so server TTS doesn't lose its first words while the device wakes from idle.
    private var keepAlive: AVAudioPlayer?
    /// Sequential playback queue for streamed server TTS (one clip per sentence).
    private var audioQueue: [Data] = []
    private var audioStreaming = false
    private var audioSealed = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Native TTS

    func speakNative(_ text: String, voiceID: String, rate: Double) {
        stopSpeaking()
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: clean)
        if !voiceID.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: voiceID) {
            utterance.voice = voice
        }
        utterance.rate = Float(rate)
        enqueue([utterance])
    }

    /// Speaks text switching voices by detected language, for bilingual language practice.
    /// Non-Latin targets (Korean, Chinese, …) split by script within a sentence; Latin targets
    /// split at sentence granularity via language detection.
    func speakBilingual(_ text: String, targetLocale: String, baseLocale: String,
                        targetVoiceID: String = "", baseVoiceID: String = "", rate: Double) {
        stopSpeaking()
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let targetVoice = Self.voice(forID: targetVoiceID) ?? Self.bestVoice(forLocale: targetLocale)
        let baseVoice = Self.voice(forID: baseVoiceID) ?? Self.bestVoice(forLocale: baseLocale)
        let segments = Self.splitByLanguage(clean, targetLocale: targetLocale, baseLocale: baseLocale)
        guard !segments.isEmpty else { return }
        let utterances = segments.map { seg -> AVSpeechUtterance in
            let u = AVSpeechUtterance(string: seg.text)
            u.voice = (seg.isTarget ? targetVoice : baseVoice) ?? targetVoice ?? baseVoice
            u.rate = Float(rate)
            return u
        }
        enqueue(utterances)
    }

    /// Enqueues native speech, chaining onto the current batch — for streaming sentence-by-sentence.
    func enqueueNative(_ text: String, voiceID: String, rate: Double) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let u = AVSpeechUtterance(string: clean)
        if !voiceID.isEmpty, let v = AVSpeechSynthesisVoice(identifier: voiceID) { u.voice = v }
        u.rate = Float(rate)
        appendUtterances([u])
    }

    /// Enqueues bilingual speech (per-language voice), chaining onto the current batch.
    func enqueueBilingual(_ text: String, targetLocale: String, baseLocale: String,
                          targetVoiceID: String = "", baseVoiceID: String = "", rate: Double) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let targetVoice = Self.voice(forID: targetVoiceID) ?? Self.bestVoice(forLocale: targetLocale)
        let baseVoice = Self.voice(forID: baseVoiceID) ?? Self.bestVoice(forLocale: baseLocale)
        let segments = Self.splitByLanguage(clean, targetLocale: targetLocale, baseLocale: baseLocale)
        guard !segments.isEmpty else { return }
        let utterances = segments.map { seg -> AVSpeechUtterance in
            let u = AVSpeechUtterance(string: seg.text)
            u.voice = (seg.isTarget ? targetVoice : baseVoice) ?? targetVoice ?? baseVoice
            u.rate = Float(rate)
            return u
        }
        appendUtterances(utterances)
    }

    /// Appends to the active batch (same generation); starts a fresh batch if nothing is queued.
    private func appendUtterances(_ utterances: [AVSpeechUtterance]) {
        guard !utterances.isEmpty else { return }
        if pendingUtterances <= 0 { enqueue(utterances); return }
        let gen = speechGeneration
        pendingUtterances += utterances.count
        isSpeaking = true
        for u in utterances {
            utteranceGenerations[ObjectIdentifier(u)] = gen
            synthesizer.speak(u)
        }
    }

    /// Starts a new speech batch under a fresh generation, tagging each utterance so late
    /// callbacks from a prior batch are ignored.
    private func enqueue(_ utterances: [AVSpeechUtterance]) {
        speechGeneration &+= 1
        let gen = speechGeneration
        pendingUtterances = utterances.count
        isSpeaking = true
        for u in utterances {
            utteranceGenerations[ObjectIdentifier(u)] = gen
            synthesizer.speak(u)
        }
    }

    func stopSpeaking() {
        speechGeneration &+= 1   // invalidate any in-flight utterance callbacks
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        player?.stop()
        audioQueue.removeAll()
        audioStreaming = false
        audioSealed = false
        pendingUtterances = 0
        isSpeaking = false
    }

    static func voices() -> [AVSpeechSynthesisVoice] {
        allVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { $0.name < $1.name }
    }

    // The first call to speechVoices() cold-starts the speech subsystem and can take seconds; cache it.
    nonisolated(unsafe) private static var voiceCache: [AVSpeechSynthesisVoice]?
    static func allVoices() -> [AVSpeechSynthesisVoice] {
        if let c = voiceCache { return c }
        let v = AVSpeechSynthesisVoice.speechVoices()
        voiceCache = v
        return v
    }

    /// Preloads the (first-call-slow) system voice catalog off the main thread at launch.
    static func warmVoices() {
        guard voiceCache == nil else { return }
        Task.detached {
            let v = AVSpeechSynthesisVoice.speechVoices()
            await MainActor.run { voiceCache = v }
        }
    }

    /// Highest-quality installed voice matching a locale (exact, then language-code prefix).
    static func bestVoice(forLocale locale: String) -> AVSpeechSynthesisVoice? {
        let code = String(locale.prefix(2)).lowercased()
        let candidates = allVoices().filter {
            $0.language.lowercased() == locale.lowercased() || $0.language.lowercased().hasPrefix(code)
        }
        return candidates.max { qualityRank($0) < qualityRank($1) }
    }

    private static func qualityRank(_ v: AVSpeechSynthesisVoice) -> Int {
        switch v.quality {
        case .premium: return 3
        case .enhanced: return 2
        default: return 1
        }
    }

    /// A specific installed voice by identifier, or nil (empty id → automatic).
    static func voice(forID id: String) -> AVSpeechSynthesisVoice? {
        id.isEmpty ? nil : AVSpeechSynthesisVoice(identifier: id)
    }

    /// Installed voices matching a locale, highest quality first — for the profile voice picker.
    static func installedVoices(forLocale locale: String) -> [AVSpeechSynthesisVoice] {
        let code = String(locale.prefix(2)).lowercased()
        return allVoices()
            .filter { $0.language.lowercased() == locale.lowercased() || $0.language.lowercased().hasPrefix(code) }
            .sorted { qualityRank($0) != qualityRank($1) ? qualityRank($0) > qualityRank($1) : $0.name < $1.name }
    }

    private static let latinLanguageCodes: Set<String> = [
        "en", "es", "fr", "de", "it", "pt", "nl", "sv", "tr", "pl", "vi", "id",
        "cs", "da", "fi", "nb", "no", "ro", "hu", "ca", "hr", "sk", "sl", "af"
    ]

    private static func isLatinLocale(_ locale: String) -> Bool {
        latinLanguageCodes.contains(String(locale.prefix(2)).lowercased())
    }

    /// Splits text into runs tagged target vs. base language for bilingual TTS.
    static func splitByLanguage(_ text: String, targetLocale: String, baseLocale: String) -> [(text: String, isTarget: Bool)] {
        if isLatinLocale(targetLocale) {
            return sentenceSegments(text, targetCode: String(targetLocale.prefix(2)).lowercased(),
                                    baseCode: String(baseLocale.prefix(2)).lowercased())
        }
        return scriptSegments(text)
    }

    // Non-Latin target: a non-ASCII letter is target script, an ASCII letter is base; other
    // characters attach to the current run. Handles intra-sentence switching (e.g. Korean + English).
    private static func scriptSegments(_ text: String) -> [(text: String, isTarget: Bool)] {
        var result: [(String, Bool)] = []
        var current = ""
        var currentIsTarget: Bool?
        for ch in text {
            let isTarget: Bool?
            if ch.isLetter {
                isTarget = !ch.unicodeScalars.allSatisfy { $0.isASCII }
            } else {
                isTarget = nil   // neutral: keep in current run
            }
            if let isTarget, currentIsTarget != nil, isTarget != currentIsTarget {
                result.append((current, currentIsTarget!))
                current = String(ch)
                currentIsTarget = isTarget
            } else {
                current.append(ch)
                if currentIsTarget == nil { currentIsTarget = isTarget }
            }
        }
        if !current.isEmpty { result.append((current, currentIsTarget ?? true)) }
        return result.filter { !$0.0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { (text: $0.0, isTarget: $0.1) }
    }

    // Latin target: detect language per sentence and coalesce consecutive same-language runs.
    private static func sentenceSegments(_ text: String, targetCode: String, baseCode: String) -> [(text: String, isTarget: Bool)] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        let recognizer = NLLanguageRecognizer()
        var segs: [(String, Bool)] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = String(text[range])
            recognizer.reset()
            recognizer.processString(s)
            let lang = recognizer.dominantLanguage?.rawValue ?? targetCode
            let isTarget = lang.hasPrefix(baseCode) ? false : true
            if let last = segs.last, last.1 == isTarget {
                segs[segs.count - 1].0 += s
            } else {
                segs.append((s, isTarget))
            }
            return true
        }
        return segs.isEmpty ? [(text: text, isTarget: true)] : segs.map { (text: $0.0, isTarget: $0.1) }
    }

    // MARK: - Native STT (dictation)

    func startNativeDictation(locale: String = "en-US", onUpdate: @escaping (DictationUpdate) -> Void) {
        dictationGeneration &+= 1
        let generation = dictationGeneration
        self.onDictationUpdate = onUpdate
        self.dictationLocale = locale
        lastError = nil

        // Apple invokes this on a background queue; keep it non-isolated and hop to main.
        SFSpeechRecognizer.requestAuthorization { @Sendable status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard generation == self.dictationGeneration else { return }
                guard status == .authorized else {
                    self.lastError = "Speech recognition not authorized. Enable it in System Settings › Privacy › Speech Recognition."
                    return
                }
                self.requestMicThenBegin(generation: generation)
            }
        }
    }

    private func requestMicThenBegin(generation: Int) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginDictation(generation: generation)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { @Sendable granted in
                Task { @MainActor [weak self] in
                    guard let self, generation == self.dictationGeneration else { return }
                    if granted { self.beginDictation(generation: generation) }
                    else { self.lastError = "Microphone access denied." }
                }
            }
        default:
            lastError = "Microphone access denied. Enable it in System Settings › Privacy › Microphone."
        }
    }

    private func beginDictation(generation: Int) {
        guard generation == dictationGeneration else { return }
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: dictationLocale))
        guard let recognizer, recognizer.isAvailable else {
            lastError = "Speech recognizer unavailable for \(dictationLocale)."
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        // Tap runs on a realtime audio thread; append is thread-safe on the request.
        nonisolated(unsafe) let sink = request
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
            sink.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            lastError = "Microphone unavailable: \(error.localizedDescription)"
            return
        }

        isListening = true
        recognitionTask = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let done = isFinal || error != nil
            Task { @MainActor in
                guard let self else { return }
                guard generation == self.dictationGeneration else { return }
                if let text {
                    self.onDictationUpdate?(DictationUpdate(text: text, isFinal: isFinal))
                }
                if done { self.stopDictation() }
            }
        }
    }

    func stopDictation() {
        dictationGeneration &+= 1
        onDictationUpdate = nil
        guard isListening else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isListening = false
    }

    // MARK: - Server STT (record + transcribe)

    func startRecording() {
        lastError = nil
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("konishi-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.record()
            self.recorder = recorder
            self.recordingURL = url
            isListening = true
        } catch {
            lastError = "Could not start recording: \(error.localizedDescription)"
        }
    }

    func stopRecordingAndTranscribe(config: RequestConfig) async -> String? {
        recorder?.stop()
        isListening = false
        guard let url = recordingURL, let data = try? Data(contentsOf: url) else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            return try await ChatService.transcribe(config: config, audio: data, fileName: url.lastPathComponent)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: - Server TTS playback

    func playAudioData(_ data: Data) {
        stopSpeaking()
        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            // Warm up the buffers and start slightly in the future so the output hardware is
            // running before the clock starts. Combined with the keep-alive player (which keeps
            // the device from idling between turns), this prevents the first word being clipped.
            player.prepareToPlay()
            player.play(atTime: player.deviceCurrentTime + 0.15)
            self.player = player
            isSpeaking = true
        } catch {
            lastError = "Could not play audio: \(error.localizedDescription)"
        }
    }

    // MARK: - Streamed server TTS (sentence-by-sentence)

    /// Begins a streamed batch: clips enqueued via `enqueueAudioData` play back in order.
    func beginAudioStream() {
        stopSpeaking()
        audioStreaming = true
        audioSealed = false
    }

    /// Adds a synthesized clip to the playback queue, starting playback if idle.
    func enqueueAudioData(_ data: Data) {
        guard audioStreaming else { return }
        isSpeaking = true   // only mark speaking once real audio exists, not on an empty (failed) stream
        audioQueue.append(data)
        if !(player?.isPlaying ?? false) { playNextQueued() }
    }

    /// Signals no more clips will arrive; fires `onFinishSpeaking` once the queue drains.
    func sealAudioStream() {
        guard audioStreaming else { return }
        audioSealed = true
        if audioQueue.isEmpty && !(player?.isPlaying ?? false) { finishAudioStream() }
    }

    private func playNextQueued() {
        guard audioStreaming else { return }
        guard !audioQueue.isEmpty else {
            if audioSealed { finishAudioStream() }
            return
        }
        let data = audioQueue.removeFirst()
        do {
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            p.prepareToPlay()
            p.play(atTime: p.deviceCurrentTime + 0.05)
            player = p
        } catch {
            playNextQueued()   // skip a bad clip
        }
    }

    private func finishAudioStream() {
        audioStreaming = false
        audioSealed = false
        player = nil
        isSpeaking = false
        onFinishSpeaking?()
    }

    /// Starts a silent, looping player so the shared output device stays active for the whole
    /// conversation. Without this the device idles during LLM/TTS generation and clips the first
    /// words of the next reply while it wakes (most noticeable on Bluetooth headphones).
    func startOutputKeepAlive() {
        guard keepAlive == nil, let data = Self.silentWAV(seconds: 1.0) else { return }
        do {
            let p = try AVAudioPlayer(data: data)
            p.numberOfLoops = -1
            p.volume = 0
            p.prepareToPlay()
            p.play()
            keepAlive = p
        } catch {
            keepAlive = nil
        }
    }

    func stopOutputKeepAlive() {
        keepAlive?.stop()
        keepAlive = nil
    }

    /// A minimal in-memory 16-bit PCM WAV of pure silence.
    private static func silentWAV(seconds: Double, sampleRate: Int = 24000) -> Data? {
        let channels = 1, bitsPerSample = 16
        let frameCount = max(1, Int(Double(sampleRate) * seconds))
        let dataSize = frameCount * channels * bitsPerSample / 8
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        func u32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)] }
        func u16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
        var d = Data()
        d.append(contentsOf: Array("RIFF".utf8))
        d.append(contentsOf: u32(UInt32(36 + dataSize)))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        d.append(contentsOf: u32(16))
        d.append(contentsOf: u16(1))                       // PCM
        d.append(contentsOf: u16(UInt16(channels)))
        d.append(contentsOf: u32(UInt32(sampleRate)))
        d.append(contentsOf: u32(UInt32(byteRate)))
        d.append(contentsOf: u16(UInt16(blockAlign)))
        d.append(contentsOf: u16(UInt16(bitsPerSample)))
        d.append(contentsOf: Array("data".utf8))
        d.append(contentsOf: u32(UInt32(dataSize)))
        d.append(Data(count: dataSize))                    // silence
        return d
    }
}

extension VoiceManager: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let gen = self.utteranceGenerations.removeValue(forKey: key) else { return }
            guard gen == self.speechGeneration else { return }   // stale: batch was superseded
            self.pendingUtterances -= 1
            guard self.pendingUtterances <= 0 else { return }    // wait for the last queued segment
            self.pendingUtterances = 0
            self.isSpeaking = false
            self.onFinishSpeaking?()
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in
            // Cancellation is driven by stopSpeaking()/a new batch, which already reset state;
            // just drop this utterance's bookkeeping.
            self.utteranceGenerations.removeValue(forKey: key)
        }
    }
}

extension VoiceManager: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if self.audioStreaming {
                self.playNextQueued()
            } else {
                self.isSpeaking = false
                self.onFinishSpeaking?()
            }
        }
    }
}
