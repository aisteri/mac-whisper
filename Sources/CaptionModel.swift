import Foundation

/// Caption state for gate-driven interpreter sessions: ONE stream, two
/// boundaries. Text is born grey (still transcribing), turns white the
/// MOMENT the gate settles it (not when playback reaches it — that gap
/// once left queued text invisible and the captions looked like they
/// skipped ahead), and the yellow play head sweeps the white as the
/// speakers deliver it.
///
/// Extracted from AppDelegate so the caption invariants are testable in
/// the same harness as the speech gate — screen-state bugs of the
/// "text vanished / duplicated / jumped" family must be caught by tests,
/// not by the user's eyes:
///  - `settled` is append-only (earlier text never changes or vanishes)
///  - `playedChars` is monotonic and never exceeds `settled`
///  - `grey` never overlaps `settled` (the gate owns that boundary)
///
/// Main-thread only.
final class CaptionModel {
    /// The white stream: everything the gate has settled, in order.
    private(set) var settled = ""
    /// The grey tail: the gate's still-unspoken text (set by the caller
    /// from SpeechGate.pendingText, possibly plus not-yet-agreed preview).
    var grey = ""

    /// Playback-finished utterances (mirrors the enqueue stream's joins).
    private var playedBase = ""
    /// The utterance the speakers are on, and the play head within it.
    private var speakingText = ""
    private var speakingUpTo = 0

    /// Character offset of the yellow boundary within `settled`. The
    /// playback stream can differ from `settled` by a few join spaces, so
    /// this is clamped — a cosmetic off-by-a-few, never an inversion.
    var playedChars: Int {
        let played = playedBase.count
            + (speakingText.isEmpty ? 0 : (playedBase.isEmpty ? 0 : 1) + speakingUpTo)
        return min(played, settled.count)
    }

    func reset() {
        settled = ""
        grey = ""
        playedBase = ""
        speakingText = ""
        speakingUpTo = 0
    }

    /// The gate settled `text` (it is entering the voice queue).
    func settle(_ text: String) {
        settled += settled.isEmpty ? text : " " + text
        if settled.count > 4000 {
            settled = String(settled.suffix(2000))
            playedBase = String(playedBase.suffix(2000))
        }
    }

    /// Playback reached the start of a new utterance.
    func playbackReached(_ text: String) {
        promoteSpeaking()
        speakingText = text
        speakingUpTo = 0
    }

    /// The play head moved within the current utterance; empty text is the
    /// drain signal (playback finished everything).
    func progress(text: String, upTo: Int) {
        if text.isEmpty {
            promoteSpeaking()
        } else {
            if text != speakingText { speakingText = text }
            speakingUpTo = upTo
        }
    }

    private func promoteSpeaking() {
        guard !speakingText.isEmpty else { return }
        playedBase += playedBase.isEmpty ? speakingText : " " + speakingText
        speakingText = ""
        speakingUpTo = 0
    }
}
