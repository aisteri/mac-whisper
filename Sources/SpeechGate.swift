import Foundation

/// Decides WHEN translated text is handed to the TTS, ahead of DeepL's own
/// confirmation.
///
/// DeepL Voice delivers the target transcript as CONCLUDED text (final,
/// append-only) plus a TENTATIVE tail (rewritten wholesale as more audio
/// arrives). Speaking only concluded text is safe but late: DeepL concludes
/// a sentence seconds after the captions already show it, which is the bulk
/// of the voice's lag behind the subtitles. This gate speaks EARLY from the
/// tentative tail — a complete sentence that has survived unchanged for a
/// stability window is considered settled and spoken immediately.
///
/// **The unit of speech is always a complete sentence, and consistency is
/// sentence similarity — never character offsets.** The first design tracked
/// spoken text by character count and skipped that many concluded chars;
/// measurement showed DeepL rewrites sentences at conclusion time in the
/// majority of cases (usually just the verb ending), and a count-based skip
/// then leaks ending fragments ("니다.") into the voice. Instead, every
/// spoken sentence is remembered in normalized form; when the conclusion
/// later delivers the same sentence — even reworded — it matches by
/// similarity and is skipped whole. A mismatch can only ever produce a
/// complete extra sentence, not a fragment. Corrections belong to the
/// captions, which update instantly; the voice never re-speaks.
///
/// Main-thread only (matching SpeechOutput, which it feeds).
final class SpeechGate {
    /// Receives each newly speakable piece of text (= speechOutput.enqueue).
    var speak: ((String) -> Void)?
    /// When false, only concluded sentences pass (no early speech).
    var earlySpeech = true

    /// Chars of the concluded stream already moved into `assembling`.
    private var spokenConcluded = 0
    /// Concluded text still waiting for its sentence to complete. The next
    /// delta appends here; whole sentences are extracted, deduped, spoken.
    private var assembling = ""
    /// Normalized forms of recently spoken sentences, oldest first. `at` is
    /// the early-speak time (nil when spoken from the conclusion), for the
    /// conclude-lag diagnostic.
    private var spokenRecent: [(norm: String, at: Date?)] = []
    private let spokenRecentCap = 8

    /// Unspoken stable-sentence candidate being watched for stability.
    private var candidate = ""
    private var candidateSince = Date()
    private var candidateDeadline = Date()
    /// Fires the candidate when updates stop arriving — a speaker pausing is
    /// exactly when the tentative text is most settled and most overdue.
    private var fireTimer: DispatchWorkItem?

    /// Stability windows: a sentence with text already following it has its
    /// ending locked in and firms up fast; the LAST sentence of the
    /// tentative is where DeepL's conclusion rewrites endings, so it must
    /// prove itself longer.
    private let stabilityFollowed: TimeInterval = 0.6
    private let stabilityAtEnd: TimeInterval = 1.2

    // MARK: - Lifecycle

    /// Session start: forget everything.
    func reset() {
        spokenConcluded = 0
        assembling = ""
        spokenRecent = []
        clearCandidate()
    }

    /// The session died mid-flight: its tentative text will never conclude.
    /// Only the candidate is dropped — `assembling` stays (the reconnect
    /// base folds a "\n" into the concluded stream, which flushes it as a
    /// sentence boundary), and spoken history must survive to dedup any
    /// text the new session re-concludes.
    func tentativeInvalidated() {
        clearCandidate()
    }

    // MARK: - Input

    /// Feed every target-transcript update here. `concludedStream` is the
    /// full concluded text including any reconnect base; `tentative` is the
    /// current unstable tail.
    func update(concludedStream: String, tentative: String) {
        if concludedStream.count > spokenConcluded {
            assembling += String(concludedStream.dropFirst(spokenConcluded))
            spokenConcluded = concludedStream.count
            settleAssembled()
        }
        guard earlySpeech else { return }
        considerUnstable(tentative)
    }

    // MARK: - Concluded settlement

    /// Extracts whole sentences from the assembly buffer; each is either
    /// deduped against what was already spoken early, or spoken in full.
    private func settleAssembled() {
        let (sentences, remainder) = Self.splitSentences(assembling)
        guard !sentences.isEmpty else { return }
        assembling = remainder
        var toSpeak = ""
        for sentence in sentences {
            if let earlyAt = consumeSpoken(matching: sentence) {
                if let earlyAt {
                    let ms = Int(Date().timeIntervalSince(earlyAt) * 1000)
                    SpeechService.diag("gate conclude-lag=\(ms)ms (sentence spoken that far ahead)")
                }
            } else {
                toSpeak += toSpeak.isEmpty ? sentence : " " + sentence
                remember(sentence, at: nil)
            }
        }
        if !toSpeak.isEmpty { speak?(toSpeak) }
    }

    /// Removes and returns the spoken-history entry similar to `sentence`
    /// (double optional: outer nil = no match / speak it; inner value = the
    /// early-speak timestamp, nil when it was spoken from the conclusion).
    private func consumeSpoken(matching sentence: String) -> Date?? {
        let norm = Self.normalize(sentence)
        // Very short sentences ("네.") legitimately repeat in meetings —
        // never dedup them. (Scalar count: ~2-3 jamo per Hangul syllable.)
        guard norm.unicodeScalars.count > 5 else { return .none }
        for (i, entry) in spokenRecent.enumerated() where Self.similar(norm, entry.norm) {
            spokenRecent.remove(at: i)
            return .some(entry.at)
        }
        return .none
    }

    private func remember(_ sentence: String, at: Date?) {
        spokenRecent.append((norm: Self.normalize(sentence), at: at))
        if spokenRecent.count > spokenRecentCap {
            spokenRecent.removeFirst(spokenRecent.count - spokenRecentCap)
        }
    }

    // MARK: - Early speech from the unstable region

    /// The unstable region is the concluded-but-unfinished tail plus the
    /// whole tentative. Complete sentences in it that were not already
    /// spoken form the candidate; the candidate speaks once it has stayed
    /// unchanged long enough.
    private func considerUnstable(_ tentative: String) {
        let (sentences, remainder) = Self.splitSentences(assembling + tentative)
        var unspoken: [String] = []
        for sentence in sentences {
            let norm = Self.normalize(sentence)
            if norm.unicodeScalars.count <= 5 { continue } // too short to trust early
            if spokenRecent.contains(where: { Self.similar(norm, $0.norm) }) { continue }
            unspoken.append(sentence)
        }
        let newCandidate = unspoken.joined(separator: " ")
        guard !newCandidate.isEmpty else {
            clearCandidate()
            return
        }
        // A candidate with text already flowing after it has its ending
        // pinned down; one sitting at the very end is still being reworded.
        let window = remainder.trimmingCharacters(in: .whitespaces).isEmpty
            ? stabilityAtEnd : stabilityFollowed
        if newCandidate != candidate {
            clearCandidate()
            candidate = newCandidate
            candidateSince = Date()
        }
        let deadline = candidateSince.addingTimeInterval(window)
        if Date() >= deadline {
            fire()
        } else if fireTimer == nil || deadline != candidateDeadline {
            armTimer(at: deadline)
        }
    }

    private func armTimer(at deadline: Date) {
        fireTimer?.cancel()
        candidateDeadline = deadline
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.fireTimer = nil
            if !self.candidate.isEmpty { self.fire() }
        }
        fireTimer = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0.02, deadline.timeIntervalSinceNow), execute: work)
    }

    private func fire() {
        let stableMs = Int(Date().timeIntervalSince(candidateSince) * 1000)
        SpeechService.diag("gate early-speak chars=\(candidate.count) stable=\(stableMs)ms")
        let now = Date()
        for sentence in Self.splitSentences(candidate).sentences {
            remember(sentence, at: now)
        }
        let text = candidate
        clearCandidate()
        speak?(text)
    }

    private func clearCandidate() {
        candidate = ""
        fireTimer?.cancel()
        fireTimer = nil
    }

    // MARK: - Sentence splitting

    /// Splits leading complete sentences off `text`; `remainder` is the
    /// unfinished tail. A half-width '.' ends a sentence unless a digit or
    /// Latin letter follows — protecting "3.5" and "example.com" while still
    /// cutting Korean/Japanese text glued straight after the period (DeepL
    /// concludes sentences without a trailing space). Trailing closers ride
    /// along.
    static func splitSentences(_ text: String) -> (sentences: [String], remainder: String) {
        let hard: Set<Character> = ["。", "．", "？", "！", "?", "!", "…", "\n"]
        let closers: Set<Character> = ["\"", "'", "」", "』", ")", "]", "»", "\u{201D}", "\u{2019}"]
        var sentences: [String] = []
        var start = text.startIndex
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            var isBoundary = hard.contains(ch)
            if ch == "." {
                let next = text.index(after: i)
                isBoundary = next == text.endIndex
                    || !(text[next].isNumber || (text[next].isASCII && text[next].isLetter))
            }
            if isBoundary {
                var end = text.index(after: i)
                while end < text.endIndex, closers.contains(text[end]) {
                    end = text.index(after: end)
                }
                let sentence = String(text[start..<end])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { sentences.append(sentence) }
                start = end
                i = end
            } else {
                i = text.index(after: i)
            }
        }
        return (sentences, String(text[start...]))
    }

    // MARK: - Sentence similarity

    /// Letters and digits only, canonically decomposed — spacing and
    /// punctuation never count as a difference, and Hangul syllables break
    /// into jamo so that an ending rewrite ("합니다" → "하겠습니다") shares
    /// its prefix at the jamo level ("하" ends the common run) instead of
    /// diverging at the syllable that recomposed.
    static func normalize(_ text: String) -> String {
        String(text.decomposedStringWithCanonicalMapping.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }).lowercased()
    }

    /// Whether two normalized sentences are the same utterance, tolerating
    /// DeepL's conclusion-time rewrites (typically the verb ending) and
    /// partial-sentence early speech. Compared at the UNICODE SCALAR level:
    /// Characters are grapheme clusters, which recompose the decomposed
    /// jamo back into syllables and would hide the shared prefix again.
    static func similar(_ x: String, _ y: String) -> Bool {
        if x == y { return true }
        let a = Array(x.unicodeScalars)
        let b = Array(y.unicodeScalars)
        let minLen = min(a.count, b.count)
        let maxLen = max(a.count, b.count)
        guard minLen > 0 else { return false }
        if minLen >= 6, a.starts(with: b) || b.starts(with: a) { return true }
        // Ending rewrite: the front agrees, the lengths are comparable.
        // 0.55, not higher: Korean polite endings ("-ㅂ니다" ↔ "-하겠습니다")
        // eat a large share of a short sentence's jamo.
        let common = zip(a, b).prefix(while: ==).count
        return Double(common) >= Double(minLen) * 0.55 && maxLen <= minLen * 2
    }
}
