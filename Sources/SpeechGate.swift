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
    /// The last few spoken pieces individually, for the fuzzy neighbor
    /// check: the Apple path's recognizer re-transcribes the same audio
    /// into SEPARATE utterances (re-split, analyzer rebuilds), so the same
    /// content re-enters the concluded stream as a heavy rewrite that
    /// neither the ledger (already settled) nor the exact-substring check
    /// can see. Only the newest pieces are compared, keeping the false-
    /// positive surface small — genuinely similar NEIGHBORING sentences
    /// are rare, and a meeting speaker repeating one verbatim is fine to
    /// dedup anyway.
    private var spokenPieces: [String] = []
    private let spokenPiecesCap = 4

    /// Unspoken stable-sentence candidate being watched for stability.
    private var candidate = ""
    private var candidateSince = Date()
    private var candidateDeadline = Date()
    /// Normalized form of the last early-spoken candidate. A new candidate
    /// SIMILAR to it is a one-character-style rewrite of what was just
    /// voiced (observed: "전환이"→"전환을" re-spoke a 116-char block) and
    /// must not fire again; the conclusion will deliver whatever changed.
    private var lastFiredNorm = ""
    /// Throttles the stall diagnostic.
    private var lastStallLogAt = Date.distantPast
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
    /// 0.3 s, not longer: the next sentence starting is itself the strong
    /// signal; the incidents we saw (conclusion-time restructuring) happen
    /// regardless of how long the sentence sat stable, so extra waiting
    /// bought no accuracy — only lag.
    private let stabilityFollowed: TimeInterval = 0.3

    // MARK: - Lifecycle

    /// Session start: forget everything.
    func reset() {
        spokenConcluded = 0
        assembling = ""
        earlyBalance = 0
        earlyMarks = []
        spokenTail = ""
        spokenPieces = []
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
        // Settlement works clause by clause, matching the speaking side:
        // early speech may have covered only the leading clauses of a
        // sentence, and settling whole sentences against that partial
        // balance would swallow the unspoken tail clauses.
        for sentence in sentences.flatMap(Self.splitClauses) {
            let size = Self.normalize(sentence).unicodeScalars.count
            if wasRecentlySpoken(sentence) {
                // Direct evidence: this text was spoken verbatim (modulo
                // spacing/punctuation). Settle its ledger share too.
                if earlyBalance > 0 {
                    earlyBalance = max(0, earlyBalance - size)
                    consumeMarks(scalars: size)
                }
                SpeechService.diag("gate skip(content) bal=\(earlyBalance) \"\(sentence.prefix(40))\"")
            } else if earlyBalance > 0, earlyBalance * 5 >= size * 4 {
                // Full coverage within ending-rewrite tolerance (~±20%,
                // the measured size drift of conclusion rewrites). NOT
                // half-coverage: a partially spoken piece must fall through
                // and SPEAK — duplication over information loss.
                earlyBalance = max(0, earlyBalance - size)
                consumeMarks(scalars: size)
                SpeechService.diag("gate skip(ledger) bal=\(earlyBalance) \"\(sentence.prefix(40))\"")
            } else {
                // Speaking against an outstanding balance means this
                // conclusion outgrew its early-spoken sentence (merged with
                // unspoken content — the size check failed). Order
                // preservation says it PASSED the ledger's head, so settle
                // that head now: a zombie balance would otherwise swallow
                // the next innocent sentence (observed: a fresh sentence
                // skipped against a 28 s-old leftover). The cost is one
                // duplicated stretch here — information loss would be worse.
                if earlyBalance > 0 {
                    let head = earlyMarks.first?.scalars ?? earlyBalance
                    if !earlyMarks.isEmpty { earlyMarks.removeFirst() }
                    earlyBalance = max(0, earlyBalance - head)
                    if earlyMarks.isEmpty { earlyBalance = 0 }
                    SpeechService.diag("gate ledger write-off \(head) (conclusion outgrew early speech)")
                }
                toSpeak += toSpeak.isEmpty ? sentence : " " + sentence
                rememberSpoken(sentence)
            }
        }
        if !toSpeak.isEmpty {
            SpeechService.diag("gate speak(concluded) bal=\(earlyBalance) \"\(toSpeak.prefix(60))\"")
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
    /// lone "네" can't false-match), or it is a heavy rewrite of one of
    /// the last few spoken pieces (bigram similarity — see spokenPieces).
    private func wasRecentlySpoken(_ sentence: String) -> Bool {
        let norm = Self.normalize(sentence)
        guard norm.unicodeScalars.count >= 6 else { return false }
        if spokenTail.contains(norm) { return true }
        return spokenPieces.contains { Self.bigramSimilar(norm, $0) }
    }

    private func rememberSpoken(_ sentence: String) {
        let norm = Self.normalize(sentence)
        spokenTail += norm
        let scalars = spokenTail.unicodeScalars
        if scalars.count > spokenTailCap {
            spokenTail = String(String.UnicodeScalarView(scalars.suffix(spokenTailCap)))
        }
        if norm.unicodeScalars.count >= 6 {
            spokenPieces.append(norm)
            if spokenPieces.count > spokenPiecesCap {
                spokenPieces.removeFirst(spokenPieces.count - spokenPiecesCap)
            }
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
        var (pieces, tail) = Self.splitSentences(assembling + tentative)
        if tail.trimmingCharacters(in: .whitespaces).isEmpty {
            if !pieces.isEmpty { pieces.removeLast() } // no next sentence started: not trusted yet
        } else {
            // Salami technique: a long sentence still being formed need not
            // be waited out whole — its clauses up to the last comma with
            // text already flowing AFTER it are as pinned down as a
            // followed sentence, so they speak now. Awkward clause-by-
            // clause delivery traded for keeping pace (user's call); the
            // ledger reconciles the conclusion by size, so no dedup worry.
            let clause = Self.clauseBoundedPrefix(of: tail)
            // Clause by clause, NOT as one block: all-or-nothing coverage
            // re-spoke an already-voiced leading clause whenever a rewrite
            // grew the block past the balance (observed twice in one
            // session — "그러면 앞서…" spoken again inside its extension).
            if !clause.isEmpty { pieces.append(contentsOf: Self.splitClauses(clause)) }
        }
        var covered = 0
        var unspoken: [String] = []
        for piece in pieces {
            let norm = Self.normalize(piece)
            let size = norm.unicodeScalars.count
            if covered + size / 2 <= earlyBalance {
                covered += size // ledger says this one is already out
            } else if size >= 6, spokenTail.contains(norm) {
                continue // content evidence: spoken verbatim, size drifted
            } else {
                unspoken.append(piece)
            }
        }
        let newCandidate = unspoken.joined(separator: " ")
        let newNorm = Self.normalize(newCandidate)
        // Too short to trust ahead of the conclusion ("물론 그." was a
        // recognizer mid-word artifact), or a light rewrite of what was
        // just voiced — either way the conclusion handles it.
        guard newNorm.unicodeScalars.count >= 12,
              !Self.similar(newNorm, lastFiredNorm) else {
            if !newCandidate.isEmpty, Date().timeIntervalSince(lastStallLogAt) > 10 {
                lastStallLogAt = Date()
                SpeechService.diag("gate hold \"\(newCandidate.prefix(40))\"")
            }
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
        // Post the whole candidate to the ledger: it may end in a clause
        // fragment rather than a sentence, and the ledger only counts size.
        var (posted, clauseTail) = Self.splitSentences(candidate)
        let tail = clauseTail.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { posted.append(tail) }
        for piece in posted {
            let size = Self.normalize(piece).unicodeScalars.count
            earlyBalance += size
            earlyMarks.append((scalars: size, at: Date()))
            rememberSpoken(piece)
        }
        lastFiredNorm = Self.normalize(candidate)
        SpeechService.diag("gate speak(early) stable=\(stableMs)ms bal=\(earlyBalance) \"\(candidate.prefix(60))\"")
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

    /// Splits a sentence at its clause boundaries (comma family; a comma
    /// directly followed by a digit — "1,000" — doesn't count). The last
    /// piece carries the sentence ending. Used on the settlement side so
    /// its units match the clause-level early speech.
    static func splitClauses(_ sentence: String) -> [String] {
        let boundaries: Set<Character> = [",", "、", "，", ";", "；"]
        var clauses: [String] = []
        var start = sentence.startIndex
        var i = sentence.startIndex
        while i < sentence.endIndex {
            if boundaries.contains(sentence[i]) {
                let next = sentence.index(after: i)
                if next == sentence.endIndex || !sentence[next].isNumber {
                    let piece = String(sentence[start..<next])
                        .trimmingCharacters(in: .whitespaces)
                    if !piece.isEmpty { clauses.append(piece) }
                    start = next
                }
            }
            i = sentence.index(after: i)
        }
        let last = String(sentence[start...]).trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { clauses.append(last) }
        return clauses
    }

    /// The prefix of an unfinished sentence up to its LAST clause boundary
    /// (comma family) that already has text flowing after it — the clause
    /// version of the followed-sentence rule. Empty when no boundary
    /// qualifies or the prefix is too short to be worth voicing alone.
    /// A comma directly followed by a digit ("1,000") is not a boundary.
    static func clauseBoundedPrefix(of text: String) -> String {
        let boundaries: Set<Character> = [",", "、", "，", ";", "；"]
        var cut: String.Index?
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if boundaries.contains(ch) {
                let next = text.index(after: i)
                // Needs BOTH: not a numeric comma, and following text — a
                // trailing comma may still be rewritten with the clause.
                if next < text.endIndex, !text[next].isNumber,
                   !text[next...].trimmingCharacters(in: .whitespaces).isEmpty {
                    cut = next
                }
            }
            i = text.index(after: i)
        }
        guard let cut else { return "" }
        let prefix = String(text[..<cut])
        guard normalize(prefix).unicodeScalars.count >= 8 else { return "" }
        return prefix
    }

    /// Whether two NORMALIZED strings say the same thing through a heavy
    /// rewrite (word order moved, connectives swapped) — jamo-bigram set
    /// overlap, which survives reordering that defeats prefix comparison.
    /// 0.65, deliberately strict: structurally parallel but DIFFERENT
    /// neighboring sentences ("매출은 90만" / "지출은 80만") must not match.
    static func bigramSimilar(_ x: String, _ y: String) -> Bool {
        let a = Array(x.unicodeScalars), b = Array(y.unicodeScalars)
        // Length ratio ≤1.3: a REWRITE keeps roughly the same size. A
        // conclusion that merged NEW content past what was spoken is
        // longer — it must fall through and speak (information first).
        guard a.count >= 10, b.count >= 10,
              Double(max(a.count, b.count)) <= Double(min(a.count, b.count)) * 1.3 else { return false }
        func bigrams(_ s: [Unicode.Scalar]) -> Set<UInt64> {
            var out = Set<UInt64>()
            for i in 0..<(s.count - 1) {
                out.insert(UInt64(s[i].value) << 32 | UInt64(s[i + 1].value))
            }
            return out
        }
        let ba = bigrams(a), bb = bigrams(b)
        let inter = ba.intersection(bb).count
        let union = ba.union(bb).count
        return union > 0 && Double(inter) / Double(union) >= 0.65
    }

    /// Whether two NORMALIZED strings are light rewrites of each other —
    /// compared at the unicode-scalar (jamo) level, since Characters
    /// recompose decomposed Hangul and hide the shared prefix.
    static func similar(_ x: String, _ y: String) -> Bool {
        if x == y { return true }
        let a = Array(x.unicodeScalars)
        let b = Array(y.unicodeScalars)
        let minLen = min(a.count, b.count)
        guard minLen > 0 else { return false }
        if minLen >= 6, a.starts(with: b) || b.starts(with: a) { return true }
        let common = zip(a, b).prefix(while: ==).count
        return Double(common) >= Double(minLen) * 0.55 && max(a.count, b.count) <= minLen * 2
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
