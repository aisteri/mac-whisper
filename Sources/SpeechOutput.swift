import AVFoundation
import Foundation

/// Speaks translations aloud, continuously, like a simultaneous interpreter.
///
/// Why not one AVSpeechUtterance per translated line: the transcriber seals
/// a line at every ~0.8 s speech pause, so translations arrive as short
/// shards — and giving each shard its own utterance inserts the
/// synthesizer's per-utterance gap after every one, which is exactly the
/// stuttering this design replaces. Instead, arriving text accumulates in a
/// buffer, and each time the voice goes idle the WHOLE buffer is spoken as
/// one utterance: shards merge into a continuous stream, and nothing ever
/// interrupts speech mid-sentence. When the conversation outruns the voice,
/// the oldest buffered text is dropped — the same policy translation itself
/// uses (speech that scrolled past isn't worth reading).
///
/// Rendering goes through a private AVAudioEngine rather than
/// `synthesizer.speak`: the engine's mixer gain is independent of the
/// system output volume, so the optional ducking mode can pull the system
/// volume down while the voice keeps its loudness — original audio quiet
/// underneath, interpreter on top, like a real interpreter feed.
///
/// Main-thread only (matching the translation engine that feeds it).
final class SpeechOutput {
    /// Master switch; when off, enqueue() is a no-op.
    var enabled = false
    /// Duck the system output while speaking; restore when the voice idles.
    var duckOthers = false
    /// BCP 47 tag choosing the voice, e.g. "ko-KR".
    var languageTag = "ko-KR" {
        didSet { if languageTag != oldValue { cachedVoice = nil } }
    }
    /// Specific voice to use; empty picks the highest-quality installed
    /// voice for `languageTag` automatically.
    var voiceIdentifier = "" {
        didSet { if voiceIdentifier != oldValue { cachedVoice = nil } }
    }

    /// System volume multiplier while ducked. The engine's own output ALSO
    /// passes through the ducked system volume, so the voice is compensated
    /// with `voiceBoost` — applied in the SAMPLE domain through tanh (a soft
    /// clipper), which lets the gain go well past what a linear mixer could
    /// without hard clipping. That also makes the voice louder on outputs
    /// whose system volume cannot be ducked at all (HDMI/DP monitors expose
    /// no volume control) — there the boost is the only lever we have.
    private let duckFactor: Float = 0.35
    private let voiceBoost: Float = 2.4

    /// Base speech rate: 10% above the system default (user-tuned: default
    /// read as sluggish, +25% as rushed). When playback backs up the rate
    /// scales up to `maxRateMultiplier` so the voice catches the
    /// conversation instead of drifting ever further behind — and falls
    /// straight back once the backlog clears (re-evaluated every utterance).
    /// Backlog is measured as SCHEDULED-BUT-UNPLAYED SECONDS, not buffered
    /// characters: rendering runs ~50× realtime, so text is scheduled almost
    /// the moment it arrives and the queue lives in the player, not here.
    private let baseRateMultiplier: Double = 1.1
    private let maxRateMultiplier: Double = 1.35
    /// Pending playback (seconds) where the rate starts climbing / tops out.
    private let rateRampStart: Double = 2.0
    private let rateRampEnd: Double = 12.0

    /// How long an idle voice waits for more shards before speaking an
    /// unterminated fragment. A slow speaker produces small shards with real
    /// pauses between them; reading each one the moment it arrives yields
    /// "two words — silence — two words". Waiting a beat merges them into a
    /// phrase, while sentence-final punctuation still speaks immediately.
    /// (0.3 s, not more: the streaming path already stabilizes text upstream
    /// in SpeechGate, so most arrivals are sentence-final anyway.)
    private let aggregationDelay: TimeInterval = 0.3

    /// Drop the oldest buffered text past this size (~30 s of speech) —
    /// beyond that the voice can never catch back up to the conversation.
    private let bufferCap = 240

    /// One utterance speaks at most this much (cut at the next sentence
    /// boundary past it). Chunking keeps the pump loop turning: the rate is
    /// re-evaluated and newly arrived text merges in at every boundary,
    /// instead of one giant utterance pinning the voice minutes behind.
    private let chunkTarget = 120

    private let synthesizer = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var connectedFormat: AVAudioFormat?

    /// Resolved voice, kept across utterances — speechVoices() is too slow
    /// to consult per pump. Invalidated when the tag/identifier changes.
    private var cachedVoice: AVSpeechSynthesisVoice?

    private var buffer = ""
    /// An utterance is being RENDERED (not played — rendering finishing is
    /// what triggers the next pump, so the next utterance's audio lands
    /// behind the current one in the player with no audible gap; waiting
    /// for playback instead put the whole render latency between sentences).
    private var rendering = false
    /// Frames handed to the player since it last started, against
    /// player.playerTime — their difference is the unplayed backlog.
    private var scheduledFrames: Double = 0
    /// When the oldest unspoken text arrived (buffer was empty), for the
    /// queue-wait diagnostic; nil while nothing waits.
    private var oldestEnqueueAt: Date?
    /// Set by pump(), cleared by the first rendered PCM buffer — measures
    /// synthesis start latency (premium voices load a model on first use).
    private var utteranceStartedAt: Date?
    /// Invalidates in-flight render callbacks after a session reset.
    private var generation = 0
    /// Pending un-duck, cancelled when the next utterance starts within the
    /// grace period — without this the system volume pumps up and down in
    /// every inter-utterance gap.
    private var unduckWork: DispatchWorkItem?

    init() {
        engine.attach(player)
        // The output device can change mid-session — headset unplugged,
        // clamshell switch to the built-in speakers, AirPods connecting.
        // The engine stops itself and posts this notification; without
        // rebuilding the connection the voice goes silent on the new device.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.handleOutputDeviceChange()
        }
    }

    /// Rebuilds the render path after the system output device changed.
    /// The utterance playing at the moment of the switch is lost (its
    /// buffers were scheduled against the dead device); anything still in
    /// the text buffer resumes on the new device.
    private func handleOutputDeviceChange() {
        SpeechService.diag("speech output device changed — reconnecting engine")
        player.stop()
        scheduledFrames = 0
        if let format = connectedFormat {
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }
        rendering = false
        pump()
    }

    // MARK: - Input

    /// Adds translated text to the spoken stream. Main thread.
    func enqueue(_ text: String) {
        guard enabled else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if buffer.isEmpty { oldestEnqueueAt = Date() }
        buffer += buffer.isEmpty ? trimmed : " " + trimmed
        if buffer.count > bufferCap {
            SpeechService.diag("speech backlog \(buffer.count) chars — dropping oldest")
            var tail = String(buffer.suffix(bufferCap))
            if let space = tail.firstIndex(of: " ") {
                tail = String(tail[tail.index(after: space)...])
            }
            buffer = tail
        }
        // A finished sentence speaks now; a fragment waits a beat for the
        // shards that usually follow it (see aggregationDelay). While the
        // voice is busy, pump() is a no-op either way and the finish handler
        // picks the buffer up.
        if let last = buffer.last, ".。?？!！…".contains(last) {
            pumpNow()
        } else {
            schedulePump()
        }
    }

    private var pendingPump: DispatchWorkItem?

    private func pumpNow() {
        pendingPump?.cancel()
        pendingPump = nil
        pump()
    }

    /// One timer from the FIRST fragment — later fragments must not keep
    /// re-arming it or a steady trickle would starve the voice forever.
    private func schedulePump() {
        guard pendingPump == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingPump = nil
            self?.pump()
        }
        pendingPump = work
        DispatchQueue.main.asyncAfter(deadline: .now() + aggregationDelay, execute: work)
    }

    /// Session start: silence anything left from the previous session.
    func reset() {
        generation &+= 1
        buffer = ""
        rendering = false
        scheduledFrames = 0
        oldestEnqueueAt = nil
        utteranceStartedAt = nil
        cachedVoice = nil
        pendingPump?.cancel()
        pendingPump = nil
        player.stop()
        cancelUnduck()
        SystemAudio.unduckOutput()
    }

    /// Renders a token utterance and discards it, so a premium voice's model
    /// load (hundreds of ms to seconds on first synthesis) is paid at session
    /// start instead of delaying the first real translation.
    func prewarm() {
        guard enabled else { return }
        let utterance = AVSpeechUtterance(string: " ")
        utterance.voice = resolveVoice()
        synthesizer.write(utterance) { _ in }
    }

    /// Session end: let the voice finish what it is saying, but nothing new.
    func endSession() {
        buffer = ""
    }

    // MARK: - Pipeline

    /// Renders the next chunk of the accumulated buffer as one utterance.
    /// Text arriving while an utterance renders simply waits for the next
    /// pump — that is what merges shards into continuous speech.
    private func pump() {
        guard !rendering, !buffer.isEmpty else { return }
        rendering = true
        let text = takeChunk()
        let gen = generation

        // Queue-wait: how long the oldest text sat behind the previous
        // utterance. The rate ramp answers playback backlog with faster
        // speech.
        let waitMs = oldestEnqueueAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
        oldestEnqueueAt = buffer.isEmpty ? nil : Date()
        let pending = pendingPlaybackSeconds()
        let ramp = min(1.0, max(0.0, (pending - rateRampStart) / (rateRampEnd - rateRampStart)))
        let multiplier = baseRateMultiplier + (maxRateMultiplier - baseRateMultiplier) * ramp
        utteranceStartedAt = Date()
        SpeechService.diag(String(format: "tts pump chars=%d pending=%.1fs rate=%.2f wait=%dms",
                                  text.count, pending, multiplier, waitMs))

        if duckOthers {
            cancelUnduck()
            SystemAudio.duckOutput(to: duckFactor)
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(multiplier)
        utterance.voice = resolveVoice()

        var sawEnd = false
        synthesizer.write(utterance) { [weak self] rendered in
            // Callback thread is unspecified; scheduleBuffer is thread-safe,
            // but all state changes bounce to main.
            guard let self, let pcm = rendered as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                // End marker (can fire more than once): rendering is done.
                if sawEnd { return }
                sawEnd = true
                DispatchQueue.main.async { [weak self] in
                    self?.renderFinished(gen: gen)
                }
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.schedule(pcm, gen: gen)
            }
        }
    }

    /// Rendering finished — the player is still speaking the tail of this
    /// utterance. Pumping NOW is the whole point of the split pipeline: the
    /// next utterance renders while this one plays and its audio lands
    /// seamlessly behind, instead of the render latency becoming silence.
    private func renderFinished(gen: Int) {
        guard gen == generation else { return }
        rendering = false
        if buffer.isEmpty {
            scheduleIdleMarker(gen: gen)
        } else {
            pump()
        }
    }

    /// Seconds of audio scheduled but not yet played out.
    private func pendingPlaybackSeconds() -> Double {
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else { return 0 }
        let played = Double(playerTime.sampleTime)
        return max(0, (scheduledFrames - played) / playerTime.sampleRate)
    }

    /// Takes the next utterance's worth of text off the buffer: everything up
    /// to the first sentence boundary past `chunkTarget`, or the whole buffer
    /// when it is short (or has no boundary — never stall waiting for one).
    private func takeChunk() -> String {
        if buffer.count <= chunkTarget {
            defer { buffer = "" }
            return buffer
        }
        let terminators: Set<Character> = [".", "。", "．", "?", "？", "!", "！", "…", "\n"]
        var idx = buffer.index(buffer.startIndex, offsetBy: chunkTarget)
        while idx < buffer.endIndex, !terminators.contains(buffer[idx]) {
            idx = buffer.index(after: idx)
        }
        guard idx < buffer.endIndex else {
            defer { buffer = "" }
            return buffer
        }
        idx = buffer.index(after: idx)
        let chunk = String(buffer[..<idx])
        buffer = String(buffer[idx...]).trimmingCharacters(in: .whitespaces)
        return chunk
    }

    /// The voice for the current tag/identifier, resolved once and cached.
    /// Auto mode prefers the highest-quality installed voice — the plain
    /// `AVSpeechSynthesisVoice(language:)` default is the robotic compact
    /// voice even when the user has premium voices downloaded.
    private func resolveVoice() -> AVSpeechSynthesisVoice? {
        if let cachedVoice { return cachedVoice }
        var voice: AVSpeechSynthesisVoice?
        if !voiceIdentifier.isEmpty {
            voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)
            // A voice saved for another target language must not win —
            // Korean read by an English voice is worse than the compact one.
            if let v = voice, v.language.prefix(2) != languageTag.prefix(2) {
                voice = nil
            }
        }
        if voice == nil {
            voice = Self.bestVoice(forLanguage: languageTag)
        }
        if voice == nil {
            voice = AVSpeechSynthesisVoice(language: languageTag)
        }
        cachedVoice = voice
        SpeechService.diag("tts voice=\(voice?.identifier ?? "system-default") quality=\(voice.map { "\($0.quality.rawValue)" } ?? "-")")
        return voice
    }

    /// Highest-quality installed voice for a BCP 47 tag (premium > enhanced),
    /// exact tag match winning ties. Returns nil when only default-quality
    /// voices exist — the caller falls back to the system default then, which
    /// avoids picking one of the novelty voices at random.
    static func bestVoice(forLanguage tag: String) -> AVSpeechSynthesisVoice? {
        let lang = tag.prefix(2)
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.prefix(2) == lang && $0.quality != .default }
            .max { a, b in
                if a.quality != b.quality { return a.quality.rawValue < b.quality.rawValue }
                return (a.language == tag ? 1 : 0) < (b.language == tag ? 1 : 0)
            }
    }

    private func schedule(_ pcm: AVAudioPCMBuffer, gen: Int) {
        guard gen == generation else { return }
        if let started = utteranceStartedAt {
            utteranceStartedAt = nil
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            if ms > 250 { SpeechService.diag("tts render-start=\(ms)ms") }
        }
        if connectedFormat != pcm.format {
            engine.connect(player, to: engine.mainMixerNode, format: pcm.format)
            connectedFormat = pcm.format
        }
        // Soft-clip boost in the sample domain (see voiceBoost). tanh
        // compresses peaks smoothly, so 2.4× reads as "clearly louder"
        // rather than distorted.
        if duckOthers, let channels = pcm.floatChannelData {
            for c in 0..<Int(pcm.format.channelCount) {
                let samples = channels[c]
                for i in 0..<Int(pcm.frameLength) {
                    samples[i] = tanh(samples[i] * voiceBoost)
                }
            }
        }
        engine.mainMixerNode.outputVolume = 1.0
        if !engine.isRunning {
            do { try engine.start() } catch {
                // One retry after a fresh connect — a device swap can leave
                // the graph pointing at a dead output.
                engine.connect(player, to: engine.mainMixerNode, format: pcm.format)
                do { try engine.start() } catch {
                    SpeechService.diag("speech engine start FAILED: \(error.localizedDescription)")
                    return
                }
            }
        }
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(pcm)
        scheduledFrames += Double(pcm.frameLength)
    }

    /// Queues a marker behind all scheduled audio; when it plays out and
    /// nothing new is rendering or waiting, the voice is truly idle — time
    /// to restore the ducked system volume. (Playback completion no longer
    /// drives the pump; renderFinished does.)
    private func scheduleIdleMarker(gen: Int) {
        guard gen == generation, let format = connectedFormat,
              let marker = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) else { return }
        marker.frameLength = 1
        player.scheduleBuffer(marker) { [weak self] in
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                if !self.rendering, self.buffer.isEmpty {
                    self.scheduleUnduck()
                }
            }
        }
    }

    // MARK: - Ducking hysteresis

    /// Restore the system volume only after the voice has been idle for a
    /// good while — sentence gaps run 1–2 s, and restoring inside them made
    /// the master volume pump up and down through the whole session.
    private func scheduleUnduck() {
        guard duckOthers else { return }
        cancelUnduck()
        let work = DispatchWorkItem { SystemAudio.unduckOutput() }
        unduckWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func cancelUnduck() {
        unduckWork?.cancel()
        unduckWork = nil
    }

    // MARK: - Voice mapping

    /// BCP 47 voice tag for a DeepL target code or an LLM prompt language name.
    static func languageTag(deepl: String, llm: String) -> String {
        let deeplMap: [String: String] = [
            "KO": "ko-KR", "JA": "ja-JP", "EN-US": "en-US", "EN-GB": "en-GB",
            "ZH-HANS": "zh-CN", "ZH-HANT": "zh-TW", "DE": "de-DE",
            "FR": "fr-FR", "ES": "es-ES", "PT-BR": "pt-BR", "RU": "ru-RU",
        ]
        if let tag = deeplMap[deepl] { return tag }
        let llmMap: [String: String] = [
            "Korean": "ko-KR", "Japanese": "ja-JP", "English": "en-US",
            "Simplified Chinese": "zh-CN", "Traditional Chinese": "zh-TW",
        ]
        return llmMap[llm] ?? "en-US"
    }
}
