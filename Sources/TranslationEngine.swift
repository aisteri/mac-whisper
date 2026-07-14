import Foundation

/// Live translation for locked (interpreter) sessions.
///
/// ## Algorithm
///
/// Two published techniques, composed:
///
///  * **Re-translation** (Arivazhagan et al., 2020 — the approach Google's
///    streaming translation shipped): each request translates one whole
///    utterance from scratch. Requests are *stateless*, so a slow or lost
///    response can never corrupt state — a newer response simply supersedes
///    it. Because at most one request per slot is ever in flight, source
///    growth while a request runs is naturally *conflated*: the next request
///    picks up the latest text, and the request rate self-paces to the
///    model's latency.
///
///  * **Local agreement** (Liu et al., 2020), trailing word masked: the
///    prefix on which two consecutive hypotheses agree is committed (rendered
///    white); the rest stays draft (dimmed). Commitment is monotonic within
///    an utterance, so a committed word never flickers back.
///
/// ## Model
///
/// The transcriber emits one utterance per line and only ever appends (a
/// pause seals the current line; see LongFormTranscriber). So the engine
/// holds an append-only array of `Utterance`, each with a stable `id`. The
/// last one may be *live* (still being spoken); the rest are *sealed*.
///
/// A single representation carries every state. Translation quality is a
/// value, not a scatter of flags:
///
///   - `.none`  — not translated yet → the caption shows the SOURCE text in
///     grey, so a slow, rate-limited, or offline LLM never blanks out speech.
///   - `.draft` — a live hypothesis (or a sealed line still awaiting its
///     quality pass); split white/grey at the agreement point.
///   - `.final` — the definitive, whole-sentence translation; fully white.
///
/// Sealing needs no copying: a live utterance simply flips `sealed = true`
/// and keeps whatever `.draft` it had — that draft *is* the provisional
/// translation. The quality pass later upgrades it to `.final`.
///
/// ## Requests
///
/// Two slots run concurrently, each holding the id it is translating:
///
///   - **live**   — keeps the spoken line current (fragment prompt, zero
///     reasoning effort, reuses the prior hypothesis for prefix stability).
///   - **quality** — upgrades the newest sealed lines to `.final` (whole
///     sentence, low reasoning effort, no reuse chain — this is where
///     translation quality comes from). Lines that scroll out of the caption
///     window before their turn are abandoned, not queued: translating
///     speech nobody can see only delays the words they can.
///
/// A shared circuit breaker stops issuing requests after a run of failures
/// and resumes after a cooldown; captions fall back to source meanwhile.
///
/// Single-threaded (main). LLM completions bounce back to main. No locks.
final class TranslationEngine {
    /// English name of the target language, used verbatim in the prompt.
    var targetLanguage = "English"
    /// English name of the source language, or "Auto" to let the model detect
    /// it. Set apart from the recognition language (which drives speech-to-text).
    var sourceLanguage = TranslationLanguage.autoSource

    /// When set, translations go through DeepL instead of the LLM engine.
    /// The engine switches per session at reset() time.
    var useDeepL = false
    var deeplAPIKey = ""
    var deeplTargetLang = "KO"
    var deeplSourceLang = ""

    /// When set, translations go through Apple's on-device Translation
    /// framework: free, offline, tens of milliseconds — and by design NO
    /// network request of any kind leaves the machine for translation.
    /// The caller starts/owns the translator session.
    var appleTranslator: AppleTranslator?

    /// Fired once per utterance with its translation, the first time one is
    /// worth speaking: at seal time when a draft exists, else when the
    /// definitive translation lands. The speech pipeline (SpeechOutput)
    /// buffers and voices these; the engine only decides WHAT to say.
    var onSpeakableTranslation: ((String) -> Void)?

    /// Gate-mode alternative to onSpeakableTranslation (set → that one is
    /// suppressed): the DeepL-Voice-shaped streams SpeechGate consumes.
    /// `concluded` grows append-only — each utterance's translation is
    /// stamped in the moment it first becomes speakable. `stable` is the
    /// live line's COMMITTED prefix (local agreement: two consecutive
    /// re-translations agreed on it) — the full live text is useless to
    /// the gate because every re-translation rewrites it wholesale, so it
    /// never survives a stability window; the agreed prefix is the "short
    /// units, locked" currency the gate can speak early. `preview` is the
    /// full live translation for the caption's dimmed line. Never the
    /// untranslated source — a dead translator must not put the original
    /// language on the speakers.
    var onSpeechStreams: ((_ concluded: String, _ stable: String, _ preview: String) -> Void)?
    private var concludedSpeech = ""

    /// One styled caption run: `committed` text renders white, else dimmed.
    struct CaptionRun {
        let text: String
        let committed: Bool
    }

    /// Fired on every display change with the full translated log (for the
    /// transcript window) and the caption runs (for the overlay). Main thread.
    var onDisplay: ((_ transcript: String, _ caption: [CaptionRun]) -> Void)?

    // MARK: Tunables

    /// Below this many characters, live text is more likely recognizer noise
    /// than a translatable utterance; wait for the next revision.
    private let minLiveChars = 2
    /// Newest sealed lines eligible for a quality pass. Older ones have
    /// scrolled off the caption; their draft (if any) is good enough for the log.
    private let qualityWindow = 2
    /// Give up a sealed line's quality pass after this many failures.
    private let maxQualityAttempts = 2
    /// Caption shows this many trailing lines, broadcast style.
    private let captionLines = 3
    /// Circuit breaker: pause requests after this many consecutive failures…
    private let breakerThreshold = 6
    /// …for this long, then probe again on the next feed.
    private let breakerCooldown: TimeInterval = 30

    // MARK: State

    private enum Translation {
        case none
        case draft(text: String, committed: Int)
        case final(text: String)

        /// The translated text, or nil when untranslated.
        var text: String? {
            switch self {
            case .none: return nil
            case .draft(let t, _), .final(let t): return t
            }
        }
        var isFinal: Bool { if case .final = self { return true }; return false }
    }

    private struct Utterance {
        let id: Int
        var source: String
        var sealed: Bool
        var translation: Translation = .none
        /// The source text that `translation` currently reflects. When this
        /// differs from `source` (the live line grew), a refresh is due.
        var translatedSource: String?
        /// Failed quality-pass attempts, for give-up.
        var qualityAttempts = 0

        /// Caption runs for this line. `.none` falls back to the source text
        /// so speech is always visible even with no translation.
        func runs(trailingNewline: Bool) -> [CaptionRun] {
            let nl = trailingNewline ? "\n" : ""
            switch translation {
            case .none:
                return [CaptionRun(text: source + nl, committed: false)]
            case .final(let t):
                return [CaptionRun(text: t + nl, committed: true)]
            case .draft(let t, let committed):
                let chars = Array(t)
                let cut = min(max(0, committed), chars.count)
                var runs: [CaptionRun] = []
                if cut > 0 {
                    runs.append(CaptionRun(text: String(chars[..<cut]), committed: true))
                }
                let tail = String(chars[cut...]) + nl
                if !tail.isEmpty {
                    runs.append(CaptionRun(text: tail, committed: false))
                }
                return runs.isEmpty ? [CaptionRun(text: nl, committed: false)] : runs
            }
        }
    }

    /// A request in flight, tagged with the utterance and source it translates
    /// so a late response can be matched back by id and validated by source.
    private struct Request {
        let id: Int
        let source: String
    }

    private struct OnDeviceError: LocalizedError {
        var errorDescription: String? { "on-device translation unavailable" }
    }

    private var utterances: [Utterance] = []
    private var nextID = 0
    /// Bumped on reset/teardown; responses from an older generation are dropped.
    private var generation = 0

    private var liveRequest: Request?
    private var qualityRequest: Request?

    private var failureStreak = 0
    private var pausedUntil = Date.distantPast

    // MARK: - Lifecycle

    /// Session start: forget everything and invalidate any in-flight responses.
    func reset() {
        generation &+= 1
        utterances.removeAll()
        spokenIDs.removeAll()
        spokenSources.removeAll()
        concludedSpeech = ""
        liveRequest = nil
        qualityRequest = nil
        failureStreak = 0
        pausedUntil = .distantPast
    }

    /// Session end: invalidate in-flight responses.
    func teardown() {
        generation &+= 1
        liveRequest = nil
        qualityRequest = nil
    }

    // MARK: - Input

    /// Feeds the transcriber's full accumulated text — one utterance per line,
    /// a trailing newline meaning the last line just sealed. The transcript is
    /// append-only, so existing line indices keep their meaning and a former
    /// live line may now be sealed.
    func feed(_ text: String, stableLength: Int) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let liveSource: String? = text.hasSuffix("\n") ? nil : lines.popLast()

        // Sealed lines, by index. When a line's source changed:
        //  - it grew (the live line's last words arrived as it sealed): the
        //    draft still applies — keep it as the provisional translation.
        //  - it's unrelated text (the recognizer re-split or re-transcribed a
        //    line): the old translation is wrong, so drop it.
        // Either way the sealed text differs from what was translated, so the
        // quality pass gets fresh attempts to produce the final.
        for (i, src) in lines.enumerated() {
            if i < utterances.count {
                if utterances[i].source != src {
                    let grew = src.hasPrefix(utterances[i].source) || utterances[i].source.hasPrefix(src)
                    utterances[i].source = src
                    if !grew {
                        utterances[i].translation = .none
                        utterances[i].translatedSource = nil
                    }
                    utterances[i].qualityAttempts = 0
                }
                if !utterances[i].sealed {
                    utterances[i].sealed = true
                    // The moment a line seals with a draft, hand it to the
                    // voice immediately — don't wait for the quality pass.
                    if let text = utterances[i].translation.text {
                        emitSpeakable(text, id: utterances[i].id)
                    }
                }
                utterances[i].sealed = true
            } else {
                utterances.append(Utterance(id: mintID(), source: src, sealed: true, translatedSource: nil))
            }
        }

        // The live line. Growth keeps the existing draft (its committed prefix
        // is monotonic); the differing translatedSource triggers a refresh.
        if let liveSource {
            let i = lines.count
            if i < utterances.count {
                if utterances[i].source != liveSource {
                    utterances[i].source = liveSource
                }
                utterances[i].sealed = false
            } else {
                utterances.append(Utterance(id: mintID(), source: liveSource, sealed: false, translatedSource: nil))
            }
        }

        schedule()
        render()
    }

    private func mintID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    // MARK: - Scheduling

    /// Fills whichever request slots are free with the highest-value work.
    private func schedule() {
        guard Date() >= pausedUntil else { return }
        if liveRequest == nil, let i = liveTarget() { dispatchLive(i) }
        if qualityRequest == nil, let i = qualityTarget() { dispatchQuality(i) }
    }

    /// The live line, when it has enough text and its translation is stale.
    private func liveTarget() -> Int? {
        guard let i = utterances.indices.last, !utterances[i].sealed else { return nil }
        let u = utterances[i]
        guard u.source.count >= minLiveChars else { return nil }
        guard u.translatedSource != u.source else { return nil }
        return i
    }

    /// The newest sealed line in the caption window still owed a `.final`,
    /// that hasn't exhausted its attempts.
    private func qualityTarget() -> Int? {
        let sealedIdxs = utterances.indices.filter { utterances[$0].sealed }
        guard let newest = sealedIdxs.last else { return nil }
        for i in sealedIdxs.reversed() {
            guard i > newest - qualityWindow else { break }
            let u = utterances[i]
            if !u.translation.isFinal, u.qualityAttempts < maxQualityAttempts {
                return i
            }
        }
        return nil
    }

    // MARK: - Requests

    private func dispatchLive(_ i: Int) {
        let u = utterances[i]
        liveRequest = Request(id: u.id, source: u.source)
        let gen = generation
        if let apple = appleTranslator {
            // On-device: nothing touches the network, ever.
            apple.translate(u.source) { [weak self] text in
                DispatchQueue.main.async {
                    if let text {
                        self?.completeLive(.success(text), gen: gen)
                    } else {
                        self?.completeLive(.failure(OnDeviceError()), gen: gen)
                    }
                }
            }
        } else if useDeepL {
            SpeechService.diag("deepl live -> \(deeplTargetLang) chars=\(u.source.count)")
            DeepLTranslator.translate(u.source, targetLang: deeplTargetLang,
                                       sourceLang: deeplSourceLang.isEmpty ? nil : deeplSourceLang,
                                       apiKey: deeplAPIKey) { [weak self] result in
                DispatchQueue.main.async {
                    self?.completeLive(result.map { $0.text }, gen: gen)
                }
            }
        } else {
            let ctx = context(before: i)
            LLMRefiner.translate(
                u.source,
                to: targetLanguage,
                from: sourceLanguage,
                context: ctx?.source,
                contextTranslation: ctx?.translation,
                isFragment: true,
                previousTranslation: u.translation.text
            ) { [weak self] result in
                DispatchQueue.main.async { self?.completeLive(result, gen: gen) }
            }
        }
    }

    private func dispatchQuality(_ i: Int) {
        let u = utterances[i]
        qualityRequest = Request(id: u.id, source: u.source)
        let gen = generation
        if let apple = appleTranslator {
            // Deterministic like DeepL: a draft that covered the sealed
            // source IS the final; otherwise one on-device pass, no network.
            if case .draft(let text, _) = u.translation {
                utterances[i].translation = .final(text: text)
                utterances[i].translatedSource = u.source
                qualityRequest = nil
                emitSpeakable(text, id: u.id)
                render()
                schedule()
                return
            }
            apple.translate(u.source) { [weak self] text in
                DispatchQueue.main.async {
                    if let text {
                        self?.completeQuality(.success(text), gen: gen)
                    } else {
                        self?.completeQuality(.failure(OnDeviceError()), gen: gen)
                    }
                }
            }
        } else if useDeepL {
            // DeepL is deterministic — the quality pass would return the same
            // result as the live pass, so just promote the draft directly.
            if case .draft(let text, _) = u.translation {
                utterances[i].translation = .final(text: text)
                utterances[i].translatedSource = u.source
                qualityRequest = nil
                emitSpeakable(text, id: u.id)
                render()
                schedule()
                return
            }
            DeepLTranslator.translate(u.source, targetLang: deeplTargetLang,
                                       sourceLang: deeplSourceLang.isEmpty ? nil : deeplSourceLang,
                                       apiKey: deeplAPIKey) { [weak self] result in
                DispatchQueue.main.async {
                    self?.completeQuality(result.map { $0.text }, gen: gen)
                }
            }
        } else {
            let ctx = context(before: i)
            LLMRefiner.translate(
                u.source,
                to: targetLanguage,
                from: sourceLanguage,
                context: ctx?.source,
                contextTranslation: ctx?.translation,
                effort: "low"
            ) { [weak self] result in
                DispatchQueue.main.async { self?.completeQuality(result, gen: gen) }
            }
        }
    }

    private func completeLive(_ result: Result<String, Error>, gen: Int) {
        guard gen == generation, let req = liveRequest else { return }
        liveRequest = nil
        switch result {
        case .success(let raw):
            noteSuccess()
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, let i = index(of: req.id),
               sourceCompatible(req.source, utterances[i].source) {
                foldDraft(&utterances[i], newText: text, translatedSource: req.source)
            }
        case .failure(let error):
            SpeechService.diag("translate live FAILED: \(error.localizedDescription)")
            // The breaker protects against hammering a dead NETWORK backend;
            // on-device failures cost nothing and must not silence the engine.
            if appleTranslator == nil { noteFailure() }
        }
        render()
        schedule()
    }

    private func completeQuality(_ result: Result<String, Error>, gen: Int) {
        guard gen == generation, let req = qualityRequest else { return }
        qualityRequest = nil
        switch result {
        case .success(let raw):
            noteSuccess()
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, let i = index(of: req.id), utterances[i].source == req.source {
                utterances[i].translation = .final(text: text)
                utterances[i].translatedSource = req.source
                emitSpeakable(text, id: req.id)
            }
        case .failure(let error):
            SpeechService.diag("translate quality FAILED: \(error.localizedDescription)")
            if appleTranslator == nil { noteFailure() }
            if let i = index(of: req.id) { utterances[i].qualityAttempts += 1 }
        }
        render()
        schedule()
    }

    /// Folds a fresh live hypothesis into an utterance via local agreement.
    /// Never overwrites a `.final` (the quality pass already won). Commitment
    /// is monotonic: it only ever grows.
    private func foldDraft(_ u: inout Utterance, newText: String, translatedSource: String) {
        if u.translation.isFinal { return }
        let previous = u.translation.text ?? ""
        let agreed = Self.agreedLength(previous: previous, current: newText)
        let priorCommitted: Int = {
            if case .draft(_, let c) = u.translation { return c }
            return 0
        }()
        let committed = min(max(priorCommitted, agreed), newText.count)
        u.translation = .draft(text: newText, committed: committed)
        u.translatedSource = translatedSource
    }

    /// A response is still applicable if the utterance's source hasn't moved
    /// away from the snapshot — grown or shrunk while staying prefix-related.
    private func sourceCompatible(_ snapshot: String, _ current: String) -> Bool {
        !snapshot.isEmpty && (current.hasPrefix(snapshot) || snapshot.hasPrefix(current))
    }

    private func index(of id: Int) -> Int? {
        utterances.firstIndex { $0.id == id }
    }

    /// The two utterances before `index`, joined as translation context —
    /// live transcripts fragment heavily ("그것", "讨论会") and one fragment is
    /// often too little to disambiguate the next.
    private func context(before index: Int) -> (source: String, translation: String?)? {
        let window = utterances[max(0, index - 2)..<index]
        guard !window.isEmpty else { return nil }
        let translation = window.compactMap { $0.translation.text }.joined(separator: "\n")
        return (
            window.map { $0.source }.joined(separator: "\n"),
            translation.isEmpty ? nil : translation
        )
    }

    // MARK: - Circuit breaker

    private func noteFailure() {
        failureStreak += 1
        if failureStreak >= breakerThreshold, pausedUntil < Date() {
            pausedUntil = Date().addingTimeInterval(breakerCooldown)
            SpeechService.diag("translate paused \(Int(breakerCooldown))s after \(failureStreak) failures")
        }
    }

    private func noteSuccess() {
        failureStreak = 0
        pausedUntil = .distantPast
    }

    // MARK: - Speech hand-off

    /// Utterances already handed to the voice; each speaks exactly once even
    /// though both the seal hook and the quality pass can produce its text.
    private var spokenIDs: Set<Int> = []

    /// Normalized SOURCES of utterances already handed to the voice. The
    /// recognizer sometimes re-transcribes the same audio into a separate
    /// utterance; its translation can be reworded beyond recognition, but
    /// the source text stays nearly identical — so duplicate detection
    /// belongs at the source level, before translation scrambles it.
    private var spokenSources: [String] = []

    private func emitSpeakable(_ text: String, id: Int) {
        guard !text.isEmpty, spokenIDs.insert(id).inserted else { return }
        if let source = utterances.first(where: { $0.id == id })?.source {
            let norm = SpeechGate.normalize(source)
            if norm.unicodeScalars.count >= 10,
               spokenSources.contains(where: { SpeechGate.bigramSimilar(norm, $0) }) {
                SpeechService.diag("translate dedup(source) \"\(text.prefix(40))\"")
                return
            }
            spokenSources.append(norm)
            if spokenSources.count > 6 { spokenSources.removeFirst() }
        }
        if onSpeechStreams != nil {
            // Gate mode: the utterance joins the concluded stream (the "\n"
            // is the sentence boundary) and the gate reconciles it against
            // whatever was already early-spoken from the live line.
            concludedSpeech += text + "\n"
            notifySpeechStreams()
        } else {
            onSpeakableTranslation?(text)
        }
    }

    /// Publishes the streams; called whenever the concluded stream grew
    /// or the live translation changed (render covers the latter).
    private func notifySpeechStreams() {
        guard let onSpeechStreams else { return }
        var stable = ""
        var preview = ""
        if let u = utterances.last, !u.sealed {
            if case .draft(let text, let committed) = u.translation {
                stable = String(text.prefix(committed))
                preview = text
            } else if let text = u.translation.text {
                preview = text
            }
        }
        onSpeechStreams(concludedSpeech, stable, preview)
    }

    // MARK: - Local agreement

    /// How many characters of `current` both hypotheses agree on, pulled back
    /// to the last word boundary so a half-formed word never commits. Spaceless
    /// scripts (CJK) fall back to masking a few trailing characters.
    private static func agreedLength(previous: String, current: String) -> Int {
        guard !previous.isEmpty else { return 0 }
        let a = Array(previous), b = Array(current)
        var i = 0
        while i < min(a.count, b.count), a[i] == b[i] { i += 1 }
        if let lastSpace = b[..<i].lastIndex(where: { $0.isWhitespace }) {
            return lastSpace + 1
        }
        return max(0, i - 3)
    }

    // MARK: - Rendering

    private func render() {
        // Transcript log: translation when present, else source — a dead LLM
        // never drops information from the record.
        let transcript = utterances
            .map { $0.translation.text ?? $0.source }
            .joined(separator: "\n")

        // Caption: the newest lines, rolling. A line leaves only by scrolling
        // off the top when a newer one arrives — never by vanishing mid-read.
        let visible = utterances.suffix(captionLines)
        var caption: [CaptionRun] = []
        for (offset, u) in visible.enumerated() {
            let isLast = offset == visible.count - 1
            caption.append(contentsOf: u.runs(trailingNewline: !isLast))
        }
        onDisplay?(transcript, caption)
        notifySpeechStreams() // live translation may have changed
    }
}
