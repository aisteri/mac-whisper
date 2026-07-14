import AVFoundation
import Foundation
import ScreenCaptureKit
import Speech

/// Long-form transcription for locked (meeting-style) recordings, built on the
/// macOS 26 SpeechAnalyzer / SpeechTranscriber API.
///
/// Unlike SFSpeechRecognizer — a dictation API that treats sustained silence as
/// a failed utterance and kills the task — SpeechAnalyzer is designed for long,
/// continuous audio: silence is simply "no results yet", so a session can idle
/// through a quiet pre-meeting stretch indefinitely. No segment-restart chain,
/// no error backoff.
///
/// The raw audio is simultaneously written to `audioBackupURL` (AAC) so even a
/// total transcription failure can never lose the capture itself.
final class LongFormTranscriber {
    /// Real-time normalized RMS level in 0...1 for the waveform HUD.
    var onLevel: ((Float) -> Void)?
    /// Full accumulated transcript (finalized + volatile tail), on main.
    /// Full accumulated transcript plus how many leading characters of it are
    /// finalized (stable). Text beyond that is volatile — the recognizer may
    /// still rewrite it, so the interpreter only drafts it, never spends a
    /// quality translation on it.
    var onTranscript: ((_ text: String, _ stableLength: Int) -> Void)?
    /// Final transcript once the session fully drains, on main. Fires exactly once.
    var onFinished: ((String) -> Void)?
    /// When set, every captured buffer is also written to this file (AAC).
    var audioBackupURL: URL?

    /// Where the session captures audio from.
    enum AudioSource { case microphone, systemAudio }
    /// Set before start(). System audio uses ScreenCaptureKit (Screen
    /// Recording permission) and hears what the computer plays — for
    /// interpreting calls and videos.
    var audioSource: AudioSource = .microphone

    /// Streaming-translation mode (DeepL Voice): captured buffers go to this
    /// sink instead of the on-device recognizer — DeepL does its own ASR,
    /// segmentation, and translation server-side. Audio backup, level HUD,
    /// and session lifecycle stay exactly the same; the analyzer pipeline,
    /// VAD sealing, and the mute watchdog simply never start. Set both
    /// before start().
    var externalAudioSink: ((AVAudioPCMBuffer) -> Void)?
    var bypassAnalyzer = false

    /// Transient status for the UI (e.g. "downloading model…"), on main.
    var onStatus: ((String) -> Void)?

    private var audioEngine: AVAudioEngine?
    private var scStream: SCStream?
    private var scOutput: SystemAudioOutput?
    private var backupFile: AVAudioFile?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    private var finalizedText = ""
    private var volatileText = ""
    private var isRunning = false
    private var didFinish = false
    private let stateLock = NSLock()
    private var lastLevelDispatchAt = Date.distantPast

    /// Loudest level seen this session — distinguishes "nobody spoke" from
    /// "speech happened but transcription failed" when the transcript is empty.
    private(set) var sessionPeakLevel: Float = 0

    /// Voice-activity state; touched only on the audio callback thread (mic
    /// tap or the ScreenCaptureKit queue — one source per session).
    private var voiceActive = false
    private var lastVoiceAt = Date.distantPast
    /// Decaying envelope of recent levels; the silence threshold adapts to it
    /// so dialogue over background music still registers.
    private var levelEnvelope: Float = 0
    /// Silence long enough to end an utterance mid-sentence. Japanese (and
    /// spoken Korean) pause naturally after particles and before final
    /// endings; 0.35 s cut sentences apart there, chopping the trailing
    /// ending off and feeding fragments to the translator.
    private let utteranceSilenceGap: TimeInterval = 0.7
    /// When the hypothesis already ends in sentence-final punctuation the
    /// sentence is really over — seal faster for interpreter responsiveness.
    private let sentenceDoneSilenceGap: TimeInterval = 0.45
    /// Don't finalize while the recognizer is still writing: a finalize
    /// issued the instant the level drops commits the hypothesis BEFORE the
    /// last ~0.3 s of audio became text, which is how utterance endings got
    /// lost. Wait for the hypothesis ink to dry.
    private let volatileInkDry: TimeInterval = 0.3
    /// Audio-thread timestamp of the last finalize request (pacing).
    private var lastFinalizeAt = Date.distantPast
    /// Finalization is only ever requested when the recognizer has stopped
    /// revising: after a real silence (VAD), or when the volatile hypothesis
    /// has been stable this long. Forcing a finalize MID-utterance (the old
    /// fixed timer) made the recognizer commit a half-formed hypothesis —
    /// low-confidence words were dropped or collapsed to "." and sentences
    /// were cut at arbitrary points, splitting words across translations.
    private let volatileStableFinalizeAfter: TimeInterval = 2.0
    private let minFinalizeSpacing: TimeInterval = 1.5
    /// Past this without a finalize, any ink-dry lull commits (see the
    /// cadence note in trackVoiceActivity) — continuous speech must not
    /// starve finalization. 2.5 s ≈ a human interpreter's ear-voice span;
    /// earlier commits trade a little recognition-revision headroom for
    /// pace, which is this app's stated priority.
    private let cadenceFinalizeAfter: TimeInterval = 2.5

    private func trackVoiceActivity(_ level: Float) {
        // ~20 ms per buffer; 0.995^n halves the envelope in roughly 3 s.
        levelEnvelope = max(level, levelEnvelope * 0.995)
        // Keep the adaptive threshold LOW relative to the envelope: on a loud
        // source (system audio peaks at 1.0) a 0.2× factor put the threshold
        // at 0.2, above the energy of soft utterance endings (です/ます tails),
        // so the silence clock started while the speaker was still finishing
        // the word — and the ending got sealed off mid-syllable.
        let threshold = max(0.03, levelEnvelope * 0.08)
        let now = Date()
        // Streaming mode has no recognizer: no finalize, no watchdog.
        guard !bypassAnalyzer else { return }
        maybeRestartMutePipeline(now: now)
        if level >= threshold {
            voiceActive = true
            lastVoiceAt = now
        } else if voiceActive {
            // A real speech pause ends the utterance — but only once the
            // recognizer has caught up (ink dry) and the pause is long enough.
            // A hypothesis already ending in sentence-final punctuation seals
            // on the shorter gap; an unfinished one gets the full pause so
            // mid-sentence breathing doesn't shatter sentences into fragments.
            stateLock.lock()
            let trailing = volatileText.last(where: { !$0.isWhitespace })
            let inkDry = now.timeIntervalSince(volatileChangedAt) >= volatileInkDry
            stateLock.unlock()
            let sentenceDone = trailing.map { "。.?？!！…".contains($0) } ?? false
            let gap = sentenceDone ? sentenceDoneSilenceGap : utteranceSilenceGap
            if now.timeIntervalSince(lastVoiceAt) >= gap, inkDry {
                voiceActive = false
                SpeechService.diag("longform silence \(String(format: "%.2f", now.timeIntervalSince(lastVoiceAt)))s -> finalize+seal (sentenceDone=\(sentenceDone) envelope=\(levelEnvelope))")
                lastFinalizeAt = now
                requestFinalize(sealTurnAfter: true)
                return
            }
        }
        // Stale-hypothesis finalize: the recognizer hasn't revised its
        // volatile text for a while, so committing it loses nothing — this
        // covers sources whose background music defeats the level VAD.
        //
        // CADENCE: silence and a 2 s-stale hypothesis were the ONLY
        // finalize triggers, and a speaker who never pauses (any meeting)
        // hits neither — finalization froze for 20-30 s and then a whole
        // paragraph settled at once ("stuck, then whooshes past"; the same
        // mechanism made a ~26 s cold start). Past `cadenceFinalizeAfter`
        // without a finalize, committing during ANY brief lull (ink-dry,
        // 0.3 s) beats waiting for a full stability window — same nature
        // as the stale trigger, just impatient.
        guard now.timeIntervalSince(lastFinalizeAt) >= minFinalizeSpacing else { return }
        let sinceFinalize = now.timeIntervalSince(lastFinalizeAt)
        let requiredLull = sinceFinalize >= cadenceFinalizeAfter
            ? volatileInkDry : volatileStableFinalizeAfter
        stateLock.lock()
        let lull = now.timeIntervalSince(volatileChangedAt)
        let volatileStable = !volatileText.isEmpty && lull >= requiredLull
        stateLock.unlock()
        if volatileStable {
            if requiredLull == volatileInkDry {
                SpeechService.diag(String(format: "longform cadence finalize +%.1fs since last", sinceFinalize))
            }
            lastFinalizeAt = now
            requestFinalize()
        }
    }

    /// Asks the analyzer to finalize everything heard so far. No-op while a
    /// previous request is in flight or when there is nothing volatile.
    /// With `sealTurnAfter` (a real silence was heard), a turn boundary is
    /// written BEHIND the finalized text once the analyzer drains — the old
    /// approach of prefixing the break onto the NEXT final left the just-
    /// finished utterance in the open turn until the next speaker started,
    /// which is exactly when its quality translation stalled.
    private var finalizeInFlight = false
    private func requestFinalize(sealTurnAfter: Bool = false) {
        stateLock.lock()
        let analyzer = self.analyzer
        let shouldRun = !finalizeInFlight && !volatileText.isEmpty && analyzer != nil
        if shouldRun { finalizeInFlight = true }
        stateLock.unlock()
        guard shouldRun, let analyzer else { return }
        Task { [weak self] in
            try? await analyzer.finalize(through: nil)
            self?.finishFinalize(sealTurn: sealTurnAfter)
        }
    }

    /// Synchronous lock helper (NSLock is unavailable from async contexts).
    /// The analyzer's finalize() can return BEFORE its final result reaches
    /// the results stream, so sealing retries briefly instead of giving up —
    /// a skipped seal left the just-finished utterance open until the next
    /// speaker started, which is exactly when its translation used to stall.
    private func finishFinalize(sealTurn: Bool) {
        stateLock.lock()
        finalizeInFlight = false
        stateLock.unlock()
        guard sealTurn else { return }
        Task { [weak self] in
            for _ in 0..<10 {
                if self?.trySealTurn() != false { return }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    /// Appends the turn boundary once the finalize has drained. Returns true
    /// when sealed (or there is nothing to seal), false to retry.
    private func trySealTurn() -> Bool {
        stateLock.lock()
        var emit = false
        var done = false
        if volatileText.isEmpty {
            if !finalizedText.isEmpty, !finalizedText.hasSuffix("\n") {
                finalizedText += "\n"
                emit = true
            }
            done = true
        }
        stateLock.unlock()
        if emit {
            let combined = combinedTranscript
            let stable = stableLength
            DispatchQueue.main.async { [weak self] in self?.onTranscript?(combined, stable) }
        }
        return done
    }

    private var combinedTranscript: String {
        stateLock.lock()
        defer { stateLock.unlock() }
        if volatileText.isEmpty { return finalizedText }
        return finalizedText + volatileText
    }

    /// Character count of the finalized (stable) prefix of combinedTranscript.
    private var stableLength: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return finalizedText.count
    }

    /// Session generation. Bumped on every start() so a stale async pipeline —
    /// a run() still awaiting model download, a superseded results task, the
    /// stop() fallback timer — can never touch a newer session. Rapid Fn
    /// mashing previously let those overlap and trap inside the Speech
    /// framework (EXC_BREAKPOINT).
    private var gen = 0

    // MARK: - Mute-pipeline watchdog
    //
    // A session can come up MUTE: audio flows (levels register) but the
    // recognizer never produces a single result — seen after rapid
    // stop/start while a locale model is still settling. Users read it as
    // "transcription is broken". The watchdog detects the pattern and
    // rebuilds the analyzer pipeline in place; capture keeps running and
    // accumulated text is kept. All fields guarded by stateLock.

    /// Language of the current session, for pipeline rebuilds.
    private var sessionLanguage: RecognitionLanguage = .english
    /// When capture actually started delivering buffers (.distantFuture
    /// until then, so the watchdog can't fire during model download).
    private var audioStartedAt = Date.distantFuture
    /// When the recognizer last produced ANY result (volatile or final).
    /// nil until the first one. The watchdog compares against this, so it
    /// catches both a pipeline that comes up mute AND one that dies
    /// mid-session (audio still flowing, results stopped — the "worked fine,
    /// then froze after a pause" failure).
    private var lastResultAt: Date?
    private var pipelineRestarts = 0
    private var pipelineRestartInFlight = false
    /// Voice heard for this long with zero results means the pipeline is dead.
    private let mutePipelineTimeout: TimeInterval = 12
    /// Give up after this many consecutive rebuilds (a result resets it).
    private let maxPipelineRestarts = 3

    private func markAudioStarted() {
        stateLock.lock()
        audioStartedAt = Date()
        lastBufferAt = Date()
        stateLock.unlock()
        DispatchQueue.main.async { [weak self] in self?.startCaptureWatchdog() }
    }

    // MARK: - Capture-stream watchdog
    //
    // SCStream is known to die SILENTLY: buffers just stop arriving while
    // the stream object stays "running" (observed repeatedly: sys-audio
    // buffer counters freeze mid-session, e.g. at #500, with no error).
    // Silence is not the explanation — SCStream delivers level-0 buffers
    // when nothing plays — so a several-second gap in buffers means the
    // stream is dead. Rebuild the capture path; the transcriber/voice
    // session and the audio backup survive.

    /// When the last capture buffer arrived. Guarded by stateLock.
    private var lastBufferAt = Date.distantFuture
    private var captureWatchdogTimer: Timer?
    private var captureRestartInFlight = false
    /// Base stall timeout. A gap USUALLY means the stream died — but some
    /// meeting apps stop producing audio entirely while the far side is
    /// silent, and then no amount of restarting brings buffers back (a
    /// measured session hit a restart every 3-5 s, each one punching a
    /// hole in the audio and shredding the local recognizer). So the
    /// timeout backs off exponentially while restarts don't recover any
    /// buffers, and snaps back to the base the moment audio returns.
    private let captureStallTimeout: TimeInterval = 5
    private var captureStallBackoff: TimeInterval = 5
    private var lastCaptureRestartAt = Date.distantPast

    private func startCaptureWatchdog() {
        captureWatchdogTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkCaptureAlive()
        }
        RunLoop.main.add(timer, forMode: .common)
        captureWatchdogTimer = timer
    }

    private func checkCaptureAlive() {
        stateLock.lock()
        let last = lastBufferAt
        let running = isRunning
        stateLock.unlock()
        // Buffers arrived since the last restart: the stream is (or was)
        // alive — restarting helps again, so drop back to the base timeout.
        if last > lastCaptureRestartAt { captureStallBackoff = captureStallTimeout }
        guard running, !captureRestartInFlight, last != .distantFuture,
              Date().timeIntervalSince(max(last, lastCaptureRestartAt)) > captureStallBackoff
        else { return }
        guard audioSource == .systemAudio else {
            // A dead mic engine has not been observed; log so it becomes
            // diagnosable if it ever is.
            SpeechService.diag("capture watchdog: mic buffers stalled (no auto-restart)")
            stateLock.lock(); lastBufferAt = Date(); stateLock.unlock()
            return
        }
        if last <= lastCaptureRestartAt {
            // The previous restart recovered nothing — the SOURCE is
            // silent, not the stream dead. Back off instead of punching
            // 1-2 s holes into the audio every few seconds.
            captureStallBackoff = min(captureStallBackoff * 2, 40)
        }
        lastCaptureRestartAt = Date()
        captureRestartInFlight = true
        SpeechService.diag("capture watchdog: no buffers for \(Int(captureStallBackoff))s — restarting system capture")
        stateLock.lock()
        let stream = scStream
        scStream = nil
        scOutput = nil
        stateLock.unlock()
        Task { [weak self] in
            if let stream { try? await stream.stopCapture() }
            guard let self, self.isRunning else { return }
            do {
                try await self.startSystemCapture(reopenBackup: false)
                SpeechService.diag("capture watchdog: system capture restarted")
                // Silent recovery: this is routine SCStream babysitting
                // (dozens of times per meeting), not something the user
                // should be alarmed about. Only a FAILED restart surfaces.
            } catch {
                SpeechService.diag("capture watchdog: restart FAILED: \(error)")
                DispatchQueue.main.async { [weak self] in
                    self?.onStatus?("Audio capture lost — trying to recover…")
                }
            }
            self.stateLock.lock()
            // NOT lastBufferAt: that would fake "buffers recovered" and
            // reset the backoff. The alive-check clocks from this instead.
            self.lastCaptureRestartAt = Date()
            self.captureRestartInFlight = false
            self.stateLock.unlock()
        }
    }

    private func noteFirstResult() {
        stateLock.lock()
        let isFirst = lastResultAt == nil
        lastResultAt = Date()
        // Any result proves the pipeline is alive — only CONSECUTIVE dead
        // rebuilds should spend the restart budget.
        pipelineRestarts = 0
        let elapsed = audioStartedAt.timeIntervalSinceNow * -1
        stateLock.unlock()
        if isFirst, elapsed.isFinite, elapsed > 0 {
            SpeechService.diag(String(format: "longform first result %.1fs after audio start", elapsed))
        }
    }

    /// Called from the audio thread on every buffer (cheap checks first).
    /// Fires when the speaker is audibly talking (voiceActive) but the
    /// recognizer hasn't produced anything for mutePipelineTimeout — whether
    /// it never started (mute at birth) or died mid-session after a silence.
    private func maybeRestartMutePipeline(now: Date) {
        guard voiceActive else { return }
        stateLock.lock()
        let quietSince = lastResultAt ?? audioStartedAt
        let shouldRestart = isRunning && !pipelineRestartInFlight
            && pipelineRestarts < maxPipelineRestarts
            && sessionPeakLevel > 0.1
            && now.timeIntervalSince(quietSince) > mutePipelineTimeout
        if shouldRestart {
            pipelineRestartInFlight = true
            pipelineRestarts += 1
        }
        stateLock.unlock()
        guard shouldRestart else { return }
        SpeechService.diag("longform watchdog: voice heard but no results in \(Int(mutePipelineTimeout))s — rebuilding analyzer")
        DispatchQueue.main.async { [weak self] in
            self?.onStatus?("Recognition stalled — restarting…")
            self?.rebuildMutePipeline()
        }
    }

    /// Tears down the mute analyzer and builds a fresh one against the same
    /// running capture. Main thread (gen is only touched on main).
    private func rebuildMutePipeline() {
        guard isRunning else { return }
        gen &+= 1
        let myGen = gen
        stateLock.lock()
        let oldBuilder = inputBuilder
        inputBuilder = nil // the tap drops buffers until the new pipeline lands
        let oldAnalyzer = analyzer
        analyzer = nil
        resultsTask?.cancel()
        resultsTask = nil
        let language = sessionLanguage
        stateLock.unlock()
        oldBuilder?.finish()
        Task { [weak self] in
            try? await oldAnalyzer?.finalizeAndFinishThroughEndOfInput()
            guard let self else { return }
            do {
                let ok = try await self.setupAnalyzerPipeline(language: language, gen: myGen)
                SpeechService.diag("longform watchdog rebuild \(ok ? "OK" : "stale")")
            } catch {
                SpeechService.diag("longform watchdog rebuild FAILED: \(error)")
            }
            self.stateLock.lock()
            self.pipelineRestartInFlight = false
            self.audioStartedAt = Date() // re-arm the timeout for a second try
            self.stateLock.unlock()
        }
    }

    func start(language: RecognitionLanguage) {
        guard !isRunning else { return }
        gen &+= 1
        let myGen = gen
        isRunning = true
        didFinish = false
        stateLock.lock()
        finalizedText = ""
        volatileText = ""
        sessionPeakLevel = 0
        sessionLanguage = language
        audioStartedAt = .distantFuture
        lastResultAt = nil
        pipelineRestarts = 0
        pipelineRestartInFlight = false
        stateLock.unlock()
        tapBufferCount = 0
        voiceActive = false
        lastVoiceAt = .distantPast
        levelEnvelope = 0
        lastFinalizedAudioEnd = 0
        Task { await run(language: language, gen: myGen) }
    }

    /// Ends the session: stops capture, lets the analyzer drain, then fires
    /// onFinished with everything transcribed so far.
    func stop() {
        let myGen = gen
        guard isRunning else {
            deliverFinish(gen: myGen)
            return
        }
        isRunning = false
        stopEngine()
        if bypassAnalyzer {
            // No recognizer to drain in streaming mode — finish immediately;
            // the streaming session owns the transcript.
            deliverFinish(gen: myGen)
            return
        }
        stateLock.lock()
        let builder = inputBuilder
        inputBuilder = nil
        let analyzer = self.analyzer
        stateLock.unlock()
        builder?.finish()
        onLevel?(0)
        Task {
            // Wait for the analyzer to process everything already yielded, so
            // the last words are not cut off.
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        }
        // Safety net: if the results stream never terminates, deliver anyway.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.deliverFinish(gen: myGen)
        }
    }

    // MARK: - Session pipeline

    private func run(language: RecognitionLanguage, gen myGen: Int) async {
        SpeechService.diag("longform start lang=\(language.rawValue)")
        // The session may be stopped (or superseded) while any of the awaits
        // below are in flight; continuing to set up a dead session corrupts
        // the newer one and can trap inside the Speech framework.
        do {
            if !bypassAnalyzer {
                guard try await setupAnalyzerPipeline(language: language, gen: myGen) else {
                    deliverFinish(gen: myGen)
                    return
                }
            }
            // Use the system default input as-is. Forcing the built-in mic
            // (like push-to-talk does) records silence in clamshell mode with
            // an external display — the lid mic hears nothing — and a meeting
            // setup often has a better external mic selected anyway.
            guard myGen == gen, isRunning else { deliverFinish(gen: myGen); return }
            switch audioSource {
            case .microphone:
                try await MainActor.run { try startEngine() }
            case .systemAudio:
                try await startSystemCapture()
            }
            markAudioStarted()
            SpeechService.diag("longform running source=\(audioSource)")
        } catch {
            SpeechService.diag("longform FAILED: \(error)")
            stopEngine()
            deliverFinish(gen: myGen)
        }
    }

    /// Builds the transcriber + analyzer + results task. Returns false when
    /// the session went stale mid-setup. Shared by the initial start and the
    /// mute-pipeline watchdog (which rebuilds it while capture keeps running).
    private func setupAnalyzerPipeline(language: RecognitionLanguage, gen myGen: Int) async throws -> Bool {
        func stale() -> Bool { myGen != gen || !isRunning }
        // fastResults trades a little accuracy for much lower latency on
        // the volatile (caption) results; finals are unaffected.
        let transcriber = SpeechTranscriber(
            locale: language.locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            // Word-level audio time ranges: pauses the recognizer absorbs
            // into a run's duration are the only reliable utterance signal
            // (result-level ranges are gapless; see segmentedFinalText).
            attributeOptions: [.audioTimeRange]
        )

        // Download the long-form model for this locale if it's missing.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            SpeechService.diag("longform downloading speech assets…")
            DispatchQueue.main.async { [weak self] in
                self?.onStatus?("Downloading \(language.displayName) model…")
            }
            try await request.downloadAndInstall()
            DispatchQueue.main.async { [weak self] in self?.onStatus?("Model ready") }
        }
        guard !stale() else { return false }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            SpeechService.diag("longform FAILED: no compatible audio format")
            return false
        }
        guard !stale() else { return false }
        setPipeline(transcriber: transcriber, format: format)

        let (stream, builder) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.start(inputSequence: stream)
        guard !stale() else {
            builder.finish()
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            return false
        }
        setStream(builder: builder, analyzer: analyzer)
        startResultsTask(transcriber, gen: myGen)
        return true
    }

    /// Synchronous helpers so the async run() never touches the lock directly
    /// (NSLock is unavailable from async contexts in Swift 6 language mode).
    private func setPipeline(transcriber: SpeechTranscriber, format: AVAudioFormat) {
        stateLock.lock()
        self.transcriber = transcriber
        analyzerFormat = format
        stateLock.unlock()
    }

    private func setStream(builder: AsyncStream<AnalyzerInput>.Continuation, analyzer: SpeechAnalyzer) {
        stateLock.lock()
        inputBuilder = builder
        self.analyzer = analyzer
        stateLock.unlock()
    }

    private func startResultsTask(_ transcriber: SpeechTranscriber, gen myGen: Int) {
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, myGen == self.gen else { return }
                    self.noteFirstResult()
                    // Finals carry per-word audio time ranges; pauses hide in
                    // run durations (result-level ranges are gapless, and
                    // volatile results have no time structure at all — one
                    // range spanning all processed audio). Segment finals on
                    // those hidden pauses so the transcript gets its utterance
                    // structure the moment text is finalized. Words covering
                    // audio that was ALREADY finalized are dropped — the
                    // recognizer sometimes re-transcribes a span it committed
                    // earlier, which used to duplicate whole exchanges in the
                    // transcript (and got them re-translated).
                    let text: String
                    if result.isFinal {
                        text = Self.segmentedFinalText(result, skippingAudioBefore: lastFinalizedAudioEnd)
                        let end = result.range.end.seconds
                        if end.isFinite {
                            lastFinalizedAudioEnd = max(lastFinalizedAudioEnd, end)
                        }
                    } else {
                        text = String(result.text.characters)
                    }
                    let combined = self.fold(text: text, isFinal: result.isFinal)
                    let stable = self.stableLength
                    DispatchQueue.main.async { self.onTranscript?(combined, stable) }
                }
            } catch {
                SpeechService.diag("longform results error: \(error)")
            }
            // Results stream ended — the analyzer has fully drained.
            self?.deliverFinish(gen: myGen)
        }
    }

    /// A run whose audio span exceeds this absorbed a speech pause (average
    /// CJK character runs are ~0.15-0.25 s; word runs a little longer). Every
    /// such pause is one utterance boundary: a single "\n". There is
    /// deliberately no second tier — the old sentence-vs-turn split ("\n" vs
    /// "\n\n") rendered as blank lines between speakers, and downstream
    /// consumers only ever need "one line = one utterance".
    private static let pauseRunDuration = 0.8

    /// Continuous speech (a monologue, dubbed dialogue with no audible gaps)
    /// can keep one turn open indefinitely; once the finalized part of the
    /// open turn grows past this, seal it at a sentence boundary. This used
    /// to be 25 — tuned for an engine that committed captions only at seals —
    /// but the translation engine now commits words WITHIN the open turn
    /// (local agreement), so tiny seals bought nothing and cost a lot: each
    /// fragment translated in isolation ("그것", "토론회") reads like machine
    /// salad. Longer turns give the translator whole sentences.
    private let maxOpenTurnChars = 70

    /// Called with stateLock held, after appending finalized text. Loops:
    /// a re-transcribed or long final can land several sentences at once, and
    /// a single cut would leave the open turn still over the limit.
    private func sealOverlongOpenTurnLocked() {
        for _ in 0..<8 {
            let openStart = finalizedText.range(of: "\n", options: .backwards)?.upperBound
                ?? finalizedText.startIndex
            let open = finalizedText[openStart...]
            guard open.count >= maxOpenTurnChars else { return }
            // Cut at the FIRST sentence boundary so a multi-sentence blob
            // seals sentence by sentence, each becoming its own turn. The
            // open span never contains "\n" (it starts past the last one), so
            // this insert can never produce a blank line.
            guard let terminator = open.firstIndex(where: { ".?!。？！".contains($0) }) else { return }
            finalizedText.insert(contentsOf: "\n", at: finalizedText.index(after: terminator))
        }
    }

    /// Rebuilds a final result's text with newlines at the speech pauses the
    /// recognizer absorbed into run durations. Verified against real anime
    /// audio: a long run of spoken text starts a new utterance (the pause
    /// precedes the word), while a long punctuation/whitespace run trails one
    /// (the pause follows the mark) — so the break lands before or after
    /// accordingly. A long leading run also marks the boundary against the
    /// PREVIOUS final, which matters now that finalization runs every ~2.5 s.
    /// Furthest audio time (seconds) already committed to finalizedText;
    /// touched only from the results task.
    private var lastFinalizedAudioEnd: Double = 0

    private static func segmentedFinalText(_ result: SpeechTranscriber.Result, skippingAudioBefore cutoff: Double) -> String {
        var out = ""
        var pendingBreak = false
        for run in result.text.runs {
            // Re-transcription of audio that was already finalized — skip.
            if let range = run.audioTimeRange, range.end.seconds <= cutoff + 0.05 {
                continue
            }
            let piece = String(result.text[run.range].characters)
            let isSpoken = piece.contains { !$0.isWhitespace && !$0.isPunctuation }
            let duration = run.audioTimeRange.map { $0.end.seconds - $0.start.seconds } ?? 0
            if duration >= pauseRunDuration, isSpoken {
                pendingBreak = true
            }
            if isSpoken, pendingBreak {
                out += "\n"
                pendingBreak = false
            }
            out += piece
            if duration >= pauseRunDuration, !isSpoken {
                pendingBreak = true
            }
        }
        return out
    }

    /// When the recognizer last REVISED its volatile hypothesis; a stable
    /// hypothesis is safe to finalize. Guarded by stateLock.
    private var volatileChangedAt = Date.distantPast

    /// Merges one recognizer result into the accumulated transcript and returns
    /// the combined text. Synchronous so it is safe to call from the async
    /// results loop without touching the lock in an async context.
    private func fold(text: String, isFinal: Bool) -> String {
        stateLock.lock()
        if isFinal {
            // A final with no actual words — a bare "." from a silence or an
            // ambiguous scrap the recognizer gave up on — is noise; folding it
            // in litters the transcript (and the interpreter) with dot-only
            // sentences.
            let substantial = text.contains { $0.isLetter || $0.isNumber }
            if substantial {
                var piece = text
                // Boundary collapse: a silence seal already wrote the "\n"
                // this final opens with. Without this, seal + leading break
                // stacked into a blank line between utterances.
                if finalizedText.isEmpty || finalizedText.hasSuffix("\n") {
                    piece = String(piece.drop(while: { $0 == "\n" }))
                }
                finalizedText += piece
                sealOverlongOpenTurnLocked()
            }
            volatileText = ""
        } else if text != volatileText {
            volatileText = text
            volatileChangedAt = Date()
        }
        stateLock.unlock()
        return combinedTranscript
    }

    private func startEngine() throws {
        let engine = AVAudioEngine()
        audioEngine = engine
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "MacTranscribe", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "invalid input format"])
        }
        var boundDevice: AudioDeviceID = 0
        if let unit = inputNode.audioUnit {
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &boundDevice, &size)
        }
        SpeechService.diag("longform input \(format.sampleRate)Hz ch=\(format.channelCount) engineDevice=\(boundDevice) analyzerFormat=\(analyzerFormat.map { "\($0.sampleRate)Hz ch=\($0.channelCount)" } ?? "nil")")

        if let url = audioBackupURL {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
            let file = try? AVAudioFile(
                forWriting: url, settings: settings,
                commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            stateLock.lock()
            backupFile = file
            stateLock.unlock()
            SpeechService.diag("longform audio backup \(file == nil ? "FAILED" : "recording") -> \(url.lastPathComponent)")
        }

        if let fmt = analyzerFormat, fmt != format {
            // A silent fallback to unconverted buffers would feed the analyzer
            // a format it did not ask for — fail loudly instead.
            guard let conv = AVAudioConverter(from: format, to: fmt) else {
                throw NSError(domain: "MacTranscribe", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "cannot convert \(format.sampleRate)Hz to analyzer format \(fmt.sampleRate)Hz"])
            }
            stateLock.lock()
            converter = conv
            stateLock.unlock()
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handleTap(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private var tapBufferCount = 0
    /// Serial queue for the audio backup: AVAudioFile.write is blocking disk
    /// I/O and must never run on the real-time audio tap thread, where its
    /// latency causes glitches and frame drops.
    private let backupQueue = DispatchQueue(label: "macwhisper.audio-backup", qos: .utility)

    private func handleTap(_ buffer: AVAudioPCMBuffer) {
        // Snapshot the shared state under the lock; these properties are
        // mutated from the session pipeline on other threads.
        stateLock.lock()
        lastBufferAt = Date()
        let backup = backupFile
        let builder = inputBuilder
        let converter = self.converter
        let analyzerFormat = self.analyzerFormat
        stateLock.unlock()

        if let backup, let copy = Self.copyBuffer(buffer) {
            // Copy first — the engine reuses the tap buffer after this block
            // returns — then write off the audio thread.
            backupQueue.async { try? backup.write(from: copy) }
        }

        // Waveform level, throttled to ~50 Hz.
        let level = Self.level(from: buffer)
        trackVoiceActivity(level)
        stateLock.lock()
        if level > sessionPeakLevel { sessionPeakLevel = level }
        stateLock.unlock()
        tapBufferCount += 1
        if tapBufferCount <= 3 || tapBufferCount % 500 == 0 {
            SpeechService.diag("longform tap #\(tapBufferCount) level=\(level) frames=\(buffer.frameLength)")
        }
        let now = Date()
        if now.timeIntervalSince(lastLevelDispatchAt) >= 0.02 {
            lastLevelDispatchAt = now
            DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
        }

        externalAudioSink?(buffer)
        guard let builder else { return }
        if let converter, let analyzerFormat {
            let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 16)
            guard let converted = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }
            var fed = false
            var convError: NSError?
            converter.convert(to: converted, error: &convError) { _, outStatus in
                if fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return buffer
            }
            if convError == nil, converted.frameLength > 0 {
                builder.yield(AnalyzerInput(buffer: converted))
            }
        } else {
            builder.yield(AnalyzerInput(buffer: buffer))
        }
    }

    /// Captures the computer's own audio output via ScreenCaptureKit and
    /// feeds it through the same pipeline as the microphone tap. Requires the
    /// Screen Recording permission (prompted on first use).
    private func startSystemCapture(reopenBackup: Bool = true) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "MacTranscribe", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "no display for system-audio capture"])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 1
        // Video is unavoidable in the API; keep it as cheap as possible and
        // simply never attach a video output.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 5)

        // Open the backup file against the capture format. Skipped on a
        // watchdog restart: reopening would TRUNCATE the session's backup —
        // the existing file handle keeps appending across stream rebuilds.
        if reopenBackup, let url = audioBackupURL,
           let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1) {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
            let file = try? AVAudioFile(
                forWriting: url, settings: settings,
                commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            setBackupFile(file)
            SpeechService.diag("longform audio backup \(file == nil ? "FAILED" : "recording") -> \(url.lastPathComponent) (system audio)")
        }

        let output = SystemAudioOutput { [weak self] buffer in
            self?.processCaptured(buffer)
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "macwhisper.system-audio"))
        try await stream.startCapture()
        setSystemStream(stream, output: output)
    }

    /// Synchronous lock helpers so async code never touches NSLock directly.
    private func setBackupFile(_ file: AVAudioFile?) {
        stateLock.lock()
        backupFile = file
        stateLock.unlock()
    }

    private func setSystemStream(_ stream: SCStream, output: SystemAudioOutput) {
        stateLock.lock()
        scStream = stream
        scOutput = output
        stateLock.unlock()
    }

    /// Shared per-buffer pipeline for the system-audio path: backup, level,
    /// convert, and yield to the analyzer. Mirrors the mic tap.
    private func processCaptured(_ buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        lastBufferAt = Date()
        let backup = backupFile
        let builder = inputBuilder
        let analyzerFormat = self.analyzerFormat
        // Lazily create a converter for the capture format if it differs from
        // what the analyzer asked for.
        if converter == nil, let fmt = analyzerFormat, fmt != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: fmt)
        }
        let converter = self.converter
        stateLock.unlock()

        if let backup, let copy = Self.copyBuffer(buffer) {
            backupQueue.async { try? backup.write(from: copy) }
        }

        let level = Self.level(from: buffer)
        trackVoiceActivity(level)
        stateLock.lock()
        if level > sessionPeakLevel { sessionPeakLevel = level }
        stateLock.unlock()
        tapBufferCount += 1
        if tapBufferCount <= 3 || tapBufferCount % 500 == 0 {
            SpeechService.diag("longform sys-audio #\(tapBufferCount) level=\(level) frames=\(buffer.frameLength)")
        }
        let now = Date()
        if now.timeIntervalSince(lastLevelDispatchAt) >= 0.02 {
            lastLevelDispatchAt = now
            DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
        }

        externalAudioSink?(buffer)
        guard let builder else { return }
        if let converter, let analyzerFormat {
            let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 16)
            guard let converted = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }
            var fed = false
            var convError: NSError?
            converter.convert(to: converted, error: &convError) { _, outStatus in
                if fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return buffer
            }
            if convError == nil, converted.frameLength > 0 {
                builder.yield(AnalyzerInput(buffer: converted))
            }
        } else {
            builder.yield(AnalyzerInput(buffer: buffer))
        }
    }

    private func stopEngine() {
        if let engine = audioEngine {
            if engine.isRunning {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
            engine.reset()
        }
        audioEngine = nil
        stateLock.lock()
        let stream = scStream
        scStream = nil
        scOutput = nil
        let file = backupFile
        backupFile = nil
        stateLock.unlock()
        if let stream {
            Task { try? await stream.stopCapture() }
        }
        // Release the file on the backup queue, after any in-flight write.
        if let file { backupQueue.async { _ = file } }
    }

    private func deliverFinish(gen myGen: Int) {
        stateLock.lock()
        let alreadyDone = didFinish || myGen != gen
        if !alreadyDone { didFinish = true }
        stateLock.unlock()
        guard !alreadyDone else { return }
        isRunning = false
        // These are read by handleTap and stop() on other threads.
        stateLock.lock()
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        converter = nil
        analyzerFormat = nil
        let peak = sessionPeakLevel
        stateLock.unlock()
        let transcript = combinedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        SpeechService.diag("longform end chars=\(transcript.count) peak=\(peak)")
        DispatchQueue.main.async { [weak self] in
            self?.captureWatchdogTimer?.invalidate()
            self?.captureWatchdogTimer = nil
            self?.onFinished?(transcript)
        }
    }

    /// Deep-copies a PCM buffer so it can outlive the tap callback (the engine
    /// reuses tap buffers once the block returns).
    private static func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (s, d) in zip(src, dst) {
            guard let sData = s.mData, let dData = d.mData else { return nil }
            memcpy(dData, sData, Int(min(s.mDataByteSize, d.mDataByteSize)))
        }
        return copy
    }

    private static func level(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData, buffer.format.channelCount > 0 else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        let samples = channelData[0]
        var sum: Float = 0
        for i in 0..<frames {
            let s = samples[i]
            sum += s * s
        }
        let rms = sqrt(sum / Float(frames))
        return min(1.0, max(0.0, rms * 12.0))
    }
}

/// SCStreamOutput adapter turning audio sample buffers into AVAudioPCMBuffers.
private final class SystemAudioOutput: NSObject, SCStreamOutput {
    private let handler: (AVAudioPCMBuffer) -> Void

    init(handler: @escaping (AVAudioPCMBuffer) -> Void) {
        self.handler = handler
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio,
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd) else { return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        pcm.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        guard status == noErr else { return }
        handler(pcm)
    }
}
