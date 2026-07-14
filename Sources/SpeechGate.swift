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
/// **Reconciliation is an order ledger, not text matching.** The transcript
/// is append-only and order-preserving, so whatever was spoken early is
/// exactly what the next conclusions deliver, in order. The gate therefore
/// keeps a balance of early-spoken text (normalized scalars); a concluded
/// sentence arriving against an outstanding balance IS (a rewrite of)
/// spoken text and is skipped whole — however DeepL reworded, split, or
/// merged it. Two earlier designs failed here: character-offset skipping
/// leaked verb-ending fragments ("니다.") whenever a rewrite changed the
/// length, and per-sentence similarity matching missed half the rewrites
/// (measured), double-speaking them. The ledger never cuts a sentence and
/// never depends on a tuned threshold; its rounding error is at most one
/// whole sentence, and a content check on recently spoken text backstops
/// the rare overshoot. Corrections belong to the captions, which update
/// instantly; the voice never re-speaks.
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
    /// delta appends here; whole sentences are extracted, settled, spoken.
    private var assembling = ""

    /// The ledger: normalized scalars of early-spoken text not yet claimed
    /// by a conclusion. Also read as: the leading run of the unstable
    /// region that is already out of the speakers.
    private var earlyBalance = 0
    /// Early-spoken sizes and times not yet claimed, for the conclude-lag
    /// metric (consumed proportionally as the balance drains).
    private var earlyMarks: [(scalars: Int, at: Date)] = []
    /// Content backstop under the ledger: recently spoken text, normalized
    /// and concatenated. Catches a conclusion that outgrew its balance in
    /// rewrite, and dead-session leftovers after a reconnect reset the
    /// ledger.
    private var spokenTail = ""
    private let spokenTailCap = 600 // unicode scalars, ~5-6 sentences

    /// Unspoken stable-sentence candidate being watched for stability.
    private var candidate = ""
    private var candidateSince = Date()
    private var candidateDeadline = Date()
    /// Fires the candidate when updates stop arriving — a speaker pausing is
    /// exactly when the tentative text is most settled and most overdue.
    private var fireTimer: DispatchWorkItem?

    /// How long a followed sentence must stay unchanged before speaking.
    /// Only sentences with text already flowing AFTER them qualify at all:
    /// Korean is verb-final, so DeepL puts a provisional ending ("~입니다.")
    /// on sentences still being spoken — a "complete-looking" sentence at
    /// the very end of the tentative is routinely half of the real one
    /// (measured: every truncated-speech incident came from there). The
    /// start of the NEXT sentence is the only trustworthy completion
    /// signal; the last sentence always waits for its conclusion.
    private let stabilityFollowed: TimeInterval = 0.6

    // MARK: - Lifecycle

    /// Session start: forget everything.
    func reset() {
        spokenConcluded = 0
        assembling = ""
        earlyBalance = 0
        earlyMarks = []
        spokenTail = ""
        clearCandidate()
    }

    /// The session died mid-flight: its tentative text will never conclude,
    /// so the outstanding balance is written off — the reconnected session
    /// starts a fresh transcript and its sentences must not be skipped
    /// against a dead ledger. `assembling` stays: the reconnect base folds
    /// a "\n" into the concluded stream, which flushes it as a sentence
    /// boundary, and the content backstop dedups it if it was early-spoken.
    func tentativeInvalidated() {
        earlyBalance = 0
        earlyMarks = []
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

    /// Extracts whole sentences from the assembly buffer and settles each
    /// against the ledger: claimed by outstanding early-spoken balance →
    /// skip; recently spoken by content → skip; otherwise speak in full.
    private func settleAssembled() {
        let (sentences, remainder) = Self.splitSentences(assembling)
        guard !sentences.isEmpty else { return }
        assembling = remainder
        var toSpeak = ""
        for sentence in sentences {
            let size = Self.normalize(sentence).unicodeScalars.count
            if earlyBalance > 0, earlyBalance * 2 >= size {
                earlyBalance = max(0, earlyBalance - size)
                consumeMarks(scalars: size)
                SpeechService.diag("gate skip(ledger) \"\(sentence.prefix(40))\"")
            } else if wasRecentlySpoken(sentence) {
                SpeechService.diag("gate skip(content) \"\(sentence.prefix(40))\"")
            } else {
                toSpeak += toSpeak.isEmpty ? sentence : " " + sentence
                rememberSpoken(sentence)
            }
        }
        if !toSpeak.isEmpty {
            SpeechService.diag("gate speak(concluded) \"\(toSpeak.prefix(60))\"")
            speak?(toSpeak)
        }
    }

    /// Drains early-speak marks in proportion to the claimed scalars and
    /// logs each fully claimed mark's age — how far ahead of its conclusion
    /// that early speech ran.
    private func consumeMarks(scalars: Int) {
        var remaining = scalars
        while remaining > 0, !earlyMarks.isEmpty {
            if earlyMarks[0].scalars > remaining {
                earlyMarks[0].scalars -= remaining
                return
            }
            remaining -= earlyMarks[0].scalars
            let mark = earlyMarks.removeFirst()
            let ms = Int(Date().timeIntervalSince(mark.at) * 1000)
            SpeechService.diag("gate conclude-lag=\(ms)ms")
        }
        if earlyBalance == 0 { earlyMarks.removeAll() }
    }

    /// Content backstop: the sentence's normalized form appears within
    /// recently spoken text (six-scalar minimum so trivial echoes like a
    /// lone "네" can't false-match).
    private func wasRecentlySpoken(_ sentence: String) -> Bool {
        let norm = Self.normalize(sentence)
        return norm.unicodeScalars.count >= 6 && spokenTail.contains(norm)
    }

    private func rememberSpoken(_ sentence: String) {
        spokenTail += Self.normalize(sentence)
        let scalars = spokenTail.unicodeScalars
        if scalars.count > spokenTailCap {
            spokenTail = String(String.UnicodeScalarView(scalars.suffix(spokenTailCap)))
        }
    }

    // MARK: - Early speech from the unstable region

    /// The unstable region is the concluded-but-unfinished tail plus the
    /// whole tentative. Its leading `earlyBalance` scalars are already
    /// spoken (order preservation again); the complete sentences after
    /// that — EXCEPT the region's final sentence, which only looks complete
    /// (see stabilityFollowed) — form the candidate, which speaks once it
    /// has stayed unchanged long enough.
    private func considerUnstable(_ tentative: String) {
        var (sentences, remainder) = Self.splitSentences(assembling + tentative)
        if remainder.trimmingCharacters(in: .whitespaces).isEmpty, !sentences.isEmpty {
            sentences.removeLast() // no next sentence started: not trusted yet
        }
        var covered = 0
        var unspoken: [String] = []
        for sentence in sentences {
            let size = Self.normalize(sentence).unicodeScalars.count
            if covered + size / 2 <= earlyBalance {
                covered += size // ledger says this one is already out
            } else {
                unspoken.append(sentence)
            }
        }
        let newCandidate = unspoken.joined(separator: " ")
        guard !newCandidate.isEmpty else {
            clearCandidate()
            return
        }
        if newCandidate != candidate {
            clearCandidate()
            candidate = newCandidate
            candidateSince = Date()
        }
        let deadline = candidateSince.addingTimeInterval(stabilityFollowed)
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
        for sentence in Self.splitSentences(candidate).sentences {
            let size = Self.normalize(sentence).unicodeScalars.count
            earlyBalance += size
            earlyMarks.append((scalars: size, at: Date()))
            rememberSpoken(sentence)
        }
        SpeechService.diag("gate speak(early) stable=\(stableMs)ms \"\(candidate.prefix(60))\"")
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

    /// Letters and digits only, canonically decomposed — spacing and
    /// punctuation never count, and Hangul syllables break into jamo so
    /// ledger sizes and the content backstop are stable under ending
    /// rewrites that recompose syllables.
    static func normalize(_ text: String) -> String {
        String(text.decomposedStringWithCanonicalMapping.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }).lowercased()
    }
}
