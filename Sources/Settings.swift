import Foundation

/// Supported recognition languages exposed in the menu bar.
enum RecognitionLanguage: String, CaseIterable {
    case english = "en-US"
    case korean = "ko-KR"
    case simplifiedChinese = "zh-CN"
    case traditionalChinese = "zh-TW"
    case japanese = "ja-JP"

    var displayName: String {
        switch self {
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }

    /// The recognizer that must run to translate FROM this pinned source
    /// language. Accepts both DeepL codes ("JA") and LLM prompt names
    /// ("Japanese"). Returns nil for auto-detect, or for a language DeepL can
    /// translate but this app has no recognizer for (German, French, …) — the
    /// caller must surface that rather than silently mishearing everything.
    init?(sourceLanguage: String) {
        switch sourceLanguage {
        case "EN", "English": self = .english
        case "KO", "Korean": self = .korean
        case "JA", "Japanese": self = .japanese
        case "ZH", "Simplified Chinese": self = .simplifiedChinese
        case "Traditional Chinese": self = .traditionalChinese
        default: return nil
        }
    }

    /// "Listening…" placeholder shown in the HUD, localized to this language.
    var listeningPlaceholder: String {
        switch self {
        case .english: return "Listening…"
        case .korean: return "듣고 있어요…"
        case .simplifiedChinese: return "聆听中…"
        case .traditionalChinese: return "聆聽中…"
        case .japanese: return "聞き取り中…"
        }
    }
}

/// A language offered for live translation: `prompt` is the name used verbatim
/// in the translation prompt; `display` is what the settings UI shows.
struct TranslationLanguage {
    let prompt: String
    let display: String

    /// Target languages. Source adds an Auto-detect option in front.
    static let targets: [TranslationLanguage] = [
        TranslationLanguage(prompt: "English", display: "English"),
        TranslationLanguage(prompt: "Korean", display: "한국어"),
        TranslationLanguage(prompt: "Japanese", display: "日本語"),
        TranslationLanguage(prompt: "Simplified Chinese", display: "简体中文"),
        TranslationLanguage(prompt: "Traditional Chinese", display: "繁體中文"),
    ]
    /// Sentinel prompt value meaning "let the model detect the source".
    static let autoSource = "Auto"
    static let sources: [TranslationLanguage] =
        [TranslationLanguage(prompt: autoSource, display: "자동 감지 (Auto-detect)")] + targets
}

/// Thin wrapper around UserDefaults for persisted configuration.
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let language = "recognitionLanguage"
        static let llmEnabled = "llmEnabled"
        static let llmProvider = "llmProvider"
        static let llmBaseURL = "llmBaseURL"
        static let llmModel = "llmModel"
        static let silenceAutoStop = "silenceAutoStopEnabled"
        static let glossaryPath = "glossaryPath"
        static let subtitleOverlay = "subtitleOverlayEnabled"
        static let triggerKeyPage = "triggerKeyPage"
        static let triggerKeyUsage = "triggerKeyUsage"
        static let triggerKeyMods = "triggerKeyModifiers"
        static let longTriggerKeyPage = "longTriggerKeyPage"
        static let longTriggerKeyUsage = "longTriggerKeyUsage"
        static let longTriggerKeyMods = "longTriggerKeyModifiers"
        static let meetingNotes = "meetingNotesEnabled"
        static let interpreterTarget = "interpreterTargetLanguage"
        static let meetingNotesProvider = "meetingNotesProvider"
        static let deeplAPIKey = "deeplAPIKey"
        static let deeplEnabled = "deeplEnabled"
        static let deeplTargetLang = "deeplTargetLang"
        static let deeplSourceLang = "deeplSourceLang"
        static let interpreterSource = "interpreterSourceLanguage"
        static let liveTranslation = "liveTranslationEnabled"
        static let audioSource = "lockedAudioSource"
    }

    /// Environment variable name holding the LLM API key. Set it via
    /// `launchctl setenv MACWHISPER_LLM_API_KEY <key>` (persists for GUI launches)
    /// or place `MACWHISPER_LLM_API_KEY=<key>` in `~/.config/macwhisper/.env`.
    /// For development, a repo-local `.env` (gitignored) is sourced by `make run`.
    static let apiKeyEnvName = "MACWHISPER_LLM_API_KEY"

    /// Path to an optional user-level env file consulted when the process
    /// environment doesn't carry the key (e.g. an installed app launched from
    /// Finder). Lives outside any repo so it's never committed.
    private static var apiKeyFilePath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/macwhisper/.env")
    }

    /// Loads `KEY=VALUE` lines from a `.env`-style file into a dictionary.
    /// Ignores blank lines and `#` comments; trims surrounding whitespace and
    /// optional single/double quotes around the value.
    private static func loadEnvFile(_ url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if (val.hasPrefix("\"") && val.hasSuffix("\"")) ||
                (val.hasPrefix("'") && val.hasSuffix("'")) {
                val.removeFirst(); val.removeLast()
            }
            out[key] = val
        }
        return out
    }

    private init() {
        // Default language is English; the user can switch to any other from the menu.
        if defaults.string(forKey: Keys.language) == nil {
            defaults.set(RecognitionLanguage.english.rawValue, forKey: Keys.language)
        }
        // Silence auto-stop defaults on so ambient noise / pauses don't keep a
        // session alive. register() supplies the default without overriding a
        // user's choice.
        defaults.register(defaults: [
            Keys.silenceAutoStop: true,
            Keys.subtitleOverlay: true,
        ])
    }

    var language: RecognitionLanguage {
        get {
            let raw = defaults.string(forKey: Keys.language) ?? RecognitionLanguage.english.rawValue
            return RecognitionLanguage(rawValue: raw) ?? .english
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.language) }
    }

    var llmEnabled: Bool {
        get { defaults.bool(forKey: Keys.llmEnabled) }
        set { defaults.set(newValue, forKey: Keys.llmEnabled) }
    }

    /// Auto-stop the session after a sustained silence (VAD); also a safety net if
    /// an Fn key-up is missed.
    var silenceAutoStopEnabled: Bool {
        get { defaults.bool(forKey: Keys.silenceAutoStop) }
        set { defaults.set(newValue, forKey: Keys.silenceAutoStop) }
    }

    /// Selected provider id from `LLMProvider.all` (e.g. "openai"), or "custom".
    var llmProviderID: String {
        get { defaults.string(forKey: Keys.llmProvider) ?? "openai" }
        set { defaults.set(newValue, forKey: Keys.llmProvider) }
    }

    var llmProvider: LLMProvider { LLMProvider.provider(id: llmProviderID) }

    /// Effective base URL: derived from the selected provider, except for the
    /// custom provider where the user supplies it directly.
    var llmBaseURL: String {
        get {
            let provider = llmProvider
            if provider.isCustom {
                return defaults.string(forKey: Keys.llmBaseURL) ?? ""
            }
            return provider.baseURL
        }
        set { defaults.set(newValue, forKey: Keys.llmBaseURL) }
    }

    /// Wire protocol for the selected provider.
    var llmProtocol: LLMProtocol { llmProvider.proto }

    /// The LLM API key, read from the environment so it is never persisted to
    /// UserDefaults (a plaintext plist on disk). Resolution order:
    ///   1. `MACWHISPER_LLM_API_KEY` in the process environment
    ///      (set via `launchctl setenv`, or inherited when launched from a shell
    ///      that sourced the repo `.env` — e.g. `make run`).
    ///   2. `MACWHISPER_LLM_API_KEY` in `~/.config/macwhisper/.env`.
    /// Returns "" when not found. Read-only; there is no setter.
    var llmAPIKey: String {
        if let value = ProcessInfo.processInfo.environment[Self.apiKeyEnvName],
           !value.isEmpty {
            return value
        }
        return Self.loadEnvFile(Self.apiKeyFilePath)[Self.apiKeyEnvName] ?? ""
    }

    /// Whether the API key was resolved from the environment (for UI status).
    var llmAPIKeyIsSet: Bool { !llmAPIKey.isEmpty }

    var llmModel: String {
        get {
            let saved = defaults.string(forKey: Keys.llmModel) ?? "gpt-5.4-mini"
            // A provider's backend catalog rotates over time (ChatGPT dropped
            // gpt-5.4-mini → HTTP 400 on every request). If the saved slug is
            // no longer offered by the selected built-in provider, fall back to
            // its current default so meeting notes / refinement keep working
            // without the user having to reopen Settings. Custom providers keep
            // whatever the user typed.
            let p = llmProvider
            if !p.isCustom, !p.models.isEmpty, !p.models.contains(saved) {
                return p.defaultModel
            }
            return saved
        }
        set { defaults.set(newValue, forKey: Keys.llmModel) }
    }

    // MARK: - DeepL

    /// Which engine drives live translation: "apple" (on-device, free — the
    /// default), "llm" (the Engine LLM), or "deepl-voice" (DeepL Voice
    /// streaming). Selected in Settings ▸ Engine ▸ Translation.
    var translationProvider: String {
        get {
            // DeepL always means Voice streaming now — the text-request DeepL
            // path fed fragments from the local recognizer and inherited all
            // its problems; "deepl" migrates forward.
            if let v = defaults.string(forKey: "translationProvider") {
                return v == "deepl" ? "deepl-voice" : v
            }
            // Migrate from the old two-checkbox scheme.
            if defaults.bool(forKey: "deeplVoiceEnabled") || defaults.bool(forKey: Keys.deeplEnabled) {
                return "deepl-voice"
            }
            return "apple"
        }
        set { defaults.set(newValue, forKey: "translationProvider") }
    }

    var appleTranslationEnabled: Bool { translationProvider == "apple" }

    /// Bridges kept so call sites read naturally.
    var deeplEnabled: Bool { translationProvider.hasPrefix("deepl") }
    var deeplVoiceEnabled: Bool { translationProvider == "deepl-voice" }

    /// Model for LLM-based translation, selectable apart from the Meeting
    /// engine's model. Defaults to the Meeting model until set.
    var translationLLMModel: String {
        get { defaults.string(forKey: "translationLLMModel") ?? llmModel }
        set { defaults.set(newValue, forKey: "translationLLMModel") }
    }

    /// Audio source for translation (interpreter) sessions, separate from
    /// meeting recordings. Follows the meeting source until explicitly set.
    var translationAudioSourceIsSystem: Bool {
        get {
            guard let v = defaults.string(forKey: "translationAudioSource") else {
                return lockedAudioSourceIsSystem
            }
            return v == "system"
        }
        set { defaults.set(newValue ? "system" : "mic", forKey: "translationAudioSource") }
    }

    var deeplAPIKey: String {
        get { defaults.string(forKey: Keys.deeplAPIKey) ?? "" }
        set { defaults.set(newValue, forKey: Keys.deeplAPIKey) }
    }

    var deeplTargetLang: String {
        get { defaults.string(forKey: Keys.deeplTargetLang) ?? "KO" }
        set { defaults.set(newValue, forKey: Keys.deeplTargetLang) }
    }

    var deeplSourceLang: String {
        get { defaults.string(forKey: Keys.deeplSourceLang) ?? "" }
        set { defaults.set(newValue, forKey: Keys.deeplSourceLang) }
    }

    var speakTranslations: Bool {
        get { defaults.bool(forKey: "speakTranslations") }
        set { defaults.set(newValue, forKey: "speakTranslations") }
    }

    /// Duck the system output volume while a spoken translation plays, so
    /// the voice sits on top of the (quieted) original audio.
    var duckWhileSpeaking: Bool {
        get { defaults.bool(forKey: "duckWhileSpeaking") }
        set { defaults.set(newValue, forKey: "duckWhileSpeaking") }
    }

    /// TTS voice for spoken translations; empty means automatic — the
    /// highest-quality installed voice for the target language.
    var speechVoiceIdentifier: String {
        get { defaults.string(forKey: "speechVoiceIdentifier") ?? "" }
        set { defaults.set(newValue, forKey: "speechVoiceIdentifier") }
    }

    /// Speak stable tentative text before DeepL concludes it. Cuts several
    /// seconds off the voice's lag behind the captions; the rare early
    /// misread is corrected only on screen, never re-spoken. Default on.
    var earlySpeechEnabled: Bool {
        get { defaults.object(forKey: "earlySpeech") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "earlySpeech") }
    }

    var deeplConfigured: Bool {
        !deeplAPIKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Where locked (long-form) sessions capture audio from: the microphone,
    /// or the computer's own output (system audio via ScreenCaptureKit — for
    /// interpreting calls/videos; requires Screen Recording permission).
    var lockedAudioSourceIsSystem: Bool {
        get { defaults.string(forKey: Keys.audioSource) == "system" }
        set { defaults.set(newValue ? "system" : "mic", forKey: Keys.audioSource) }
    }

    /// When on, locked (long-form) sessions run as one-way interpretation:
    /// captions show the live translation and no minutes are generated.
    var liveTranslationEnabled: Bool {
        get { defaults.bool(forKey: Keys.liveTranslation) }
        set { defaults.set(newValue, forKey: Keys.liveTranslation) }
    }

    /// Target language for the one-way interpreter mode (English name, used
    /// verbatim in the translation prompt).
    var interpreterTargetLanguage: String {
        get { defaults.string(forKey: Keys.interpreterTarget) ?? "English" }
        set { defaults.set(newValue, forKey: Keys.interpreterTarget) }
    }

    /// Source language for live translation. "Auto" (the default) lets the
    /// model detect it; any other value is named in the prompt so mixed-
    /// language meetings translate a chosen source consistently — set apart
    /// from the recognition language, which drives speech-to-text.
    var interpreterSourceLanguage: String {
        get { defaults.string(forKey: Keys.interpreterSource) ?? TranslationLanguage.autoSource }
        set { defaults.set(newValue, forKey: Keys.interpreterSource) }
    }

    /// The source language pinned for the ACTIVE translation provider — a
    /// DeepL code when DeepL is selected, an LLM prompt name otherwise. Empty
    /// or "Auto" both mean auto-detect.
    var activeInterpreterSource: String {
        deeplEnabled ? deeplSourceLang : interpreterSourceLanguage
    }

    /// The recognizer a live-translation session must listen in. A pinned
    /// source language IS the spoken language, so it decides the recognizer;
    /// auto-detect (or a source with no recognizer) falls back to the
    /// standalone recognition language. Speech-to-text can't auto-detect, so
    /// this is always a concrete locale.
    var interpreterRecognitionLanguage: RecognitionLanguage {
        RecognitionLanguage(sourceLanguage: activeInterpreterSource) ?? language
    }

    /// True when a specific source language is pinned that no recognizer can
    /// hear (e.g. DeepL German) — the session would mistranscribe everything,
    /// so the caller should refuse to start and say why.
    var interpreterSourceUnsupportedBySTT: Bool {
        let source = activeInterpreterSource
        guard !source.isEmpty, source != TranslationLanguage.autoSource else { return false }
        return RecognitionLanguage(sourceLanguage: source) == nil
    }

    /// Generate structured meeting notes with the LLM after a locked
    /// (long-form) recording finishes. Off by default; requires a configured
    /// LLM provider. The glossary is included so domain terms come out right.
    var meetingNotesEnabled: Bool {
        get { defaults.bool(forKey: Keys.meetingNotes) }
        set { defaults.set(newValue, forKey: Keys.meetingNotes) }
    }

    /// Which provider generates meeting notes: "engine" uses the configured
    /// LLM Engine (ChatGPT/OpenAI/custom), "claude" shells out to `claude -p`.
    var meetingNotesProvider: String {
        get { defaults.string(forKey: Keys.meetingNotesProvider) ?? "engine" }
        set { defaults.set(newValue, forKey: Keys.meetingNotesProvider) }
    }

    /// Show caption-style subtitles at the bottom of the screen during a
    /// locked (long-form) recording.
    var subtitleOverlayEnabled: Bool {
        get { defaults.bool(forKey: Keys.subtitleOverlay) }
        set { defaults.set(newValue, forKey: Keys.subtitleOverlay) }
    }

    /// Custom trigger key (HID page/usage) for external keyboards. Defaults to
    /// Left Ctrl on the standard keyboard page: hold it to dictate, add Shift
    /// for the long-form toggle. The Apple Fn key (⌃Fn) always works too.
    var triggerKey: KeyChord {
        get {
            let page = defaults.integer(forKey: Keys.triggerKeyPage)
            let usage = defaults.integer(forKey: Keys.triggerKeyUsage)
            let mods = defaults.integer(forKey: Keys.triggerKeyMods)
            guard page > 0, usage > 0 else { return KeyChord(page: 0x07, usage: 0xE0, modifiersRaw: 0) }
            return KeyChord(page: UInt32(page), usage: UInt32(usage), modifiersRaw: UInt(mods))
        }
        set {
            defaults.set(Int(newValue.page), forKey: Keys.triggerKeyPage)
            defaults.set(Int(newValue.usage), forKey: Keys.triggerKeyUsage)
            defaults.set(Int(newValue.modifiersRaw), forKey: Keys.triggerKeyMods)
        }
    }

    /// Optional dedicated chord toggling the locked (long-form) recording.
    /// nil = not set; trigger+Shift is then the only long-form gesture.
    var longTriggerKey: KeyChord? {
        get {
            let page = defaults.integer(forKey: Keys.longTriggerKeyPage)
            let usage = defaults.integer(forKey: Keys.longTriggerKeyUsage)
            let mods = defaults.integer(forKey: Keys.longTriggerKeyMods)
            guard page > 0, usage > 0 else { return nil }
            return KeyChord(page: UInt32(page), usage: UInt32(usage), modifiersRaw: UInt(mods))
        }
        set {
            defaults.set(Int(newValue?.page ?? 0), forKey: Keys.longTriggerKeyPage)
            defaults.set(Int(newValue?.usage ?? 0), forKey: Keys.longTriggerKeyUsage)
            defaults.set(Int(newValue?.modifiersRaw ?? 0), forKey: Keys.longTriggerKeyMods)
        }
    }

    // MARK: - Glossary

    /// Default glossary location, used when the user hasn't attached a file.
    static var defaultGlossaryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/macwhisper/glossary.txt")
    }

    /// Path to the attached glossary text file. One term per line; `#` lines are
    /// comments; `wrong -> right` lines map a common mis-transcription to the
    /// preferred spelling.
    var glossaryURL: URL {
        get {
            if let path = defaults.string(forKey: Keys.glossaryPath), !path.isEmpty {
                return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            }
            return Self.defaultGlossaryURL
        }
        set { defaults.set(newValue.path, forKey: Keys.glossaryPath) }
    }

    /// Raw glossary text for the LLM prompt, capped so a huge file can't blow up
    /// every request. Empty string when the file is missing or empty.
    var glossaryText: String {
        guard let text = try? String(contentsOf: glossaryURL, encoding: .utf8) else { return "" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(8000))
    }

    /// Individual terms for speech-recognition hints (SFSpeechRecognizer
    /// contextualStrings). For mapping lines only the right-hand side is a real
    /// term; comments and blanks are skipped.
    var glossaryTerms: [String] {
        var terms: [String] = []
        for rawLine in glossaryText.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let term: String
            if let range = line.range(of: "->") ?? line.range(of: "→") {
                term = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else {
                term = line
            }
            if !term.isEmpty { terms.append(term) }
        }
        return Array(terms.prefix(500))
    }

    // MARK: - Translation glossary (separate file)
    //
    // The MEETING glossary corrects speech recognition (wrong-spelling ->
    // right-spelling, same language). The TRANSLATION glossary maps source-
    // language terms to target-language terms (投放 -> 캠페인 집행). Mixing
    // them in one file made each line's meaning ambiguous.

    static var defaultTranslationGlossaryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/macwhisper/translation-glossary.txt")
    }

    var translationGlossaryURL: URL {
        get {
            if let path = defaults.string(forKey: "translationGlossaryPath"), !path.isEmpty {
                return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            }
            return Self.defaultTranslationGlossaryURL
        }
        set { defaults.set(newValue.path, forKey: "translationGlossaryPath") }
    }

    var translationGlossaryText: String {
        guard let text = try? String(contentsOf: translationGlossaryURL, encoding: .utf8) else { return "" }
        return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(8000))
    }

    /// The glossary file accepts TWO formats:
    ///  - a JSON array of {"term", "ko", "jp", "en", "memo"} objects — the
    ///    team's shared terminology sheet, attached as-is; the language pair
    ///    of the session picks which columns become source/target
    ///  - plain "원어 -> 번역어" lines (language-pair agnostic)

    /// JSON entries when the file is the terminology-sheet format, else nil.
    private var translationGlossaryJSON: [[String: String]]? {
        guard let data = try? Data(contentsOf: translationGlossaryURL),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return array.map { entry in entry.compactMapValues { $0 as? String } }
    }

    /// JSON column key for a DeepL language code ("JA" -> "jp"), or nil for
    /// languages the sheet doesn't carry.
    static func glossaryColumn(deepl code: String) -> String? {
        switch code.prefix(2).uppercased() {
        case "KO": return "ko"
        case "JA": return "jp"
        case "EN": return "en"
        default: return nil
        }
    }

    /// JSON column key for an LLM prompt language name ("Japanese" -> "jp").
    static func glossaryColumn(promptName: String) -> String? {
        switch promptName {
        case "Korean": return "ko"
        case "Japanese": return "jp"
        case "English": return "en"
        default: return nil
        }
    }

    /// Translation pairs for a language pair. For the JSON sheet, the source
    /// column's spellings (split on "、,/" — the sheet lists variants) map to
    /// the target column's first spelling; the "term" column doubles as a
    /// source spelling for Korean (it is the sheet's Korean-keyed handle).
    /// nil sourceColumn (auto-detect) uses "term" + every language column as
    /// possible source spellings. Plain "A -> B" files return their lines.
    func translationGlossaryPairs(sourceColumn: String?, targetColumn: String) -> [(String, String)] {
        guard let entries = translationGlossaryJSON else { return arrowLinePairs }
        var seenSources = Set<String>()
        var pairs: [(String, String)] = []
        for entry in entries {
            guard let rawTarget = entry[targetColumn]?.trimmingCharacters(in: .whitespaces),
                  !rawTarget.isEmpty else { continue }
            let target = Self.splitSpellings(rawTarget).first ?? rawTarget

            var sourceSpellings: [String] = []
            if let column = sourceColumn {
                if let s = entry[column] { sourceSpellings += Self.splitSpellings(s) }
                if column == "ko", let term = entry["term"] { sourceSpellings += Self.splitSpellings(term) }
            } else {
                for key in ["term", "ko", "jp", "en"] {
                    if let s = entry[key] { sourceSpellings += Self.splitSpellings(s) }
                }
            }
            for source in sourceSpellings
            where !source.isEmpty && source != target && seenSources.insert(source).inserted {
                pairs.append((source, target))
            }
        }
        return Array(pairs.prefix(500))
    }

    /// A sheet cell can list variants: "台本、脚本" / "RoFO, Right of First Offer".
    private static func splitSpellings(_ value: String) -> [String] {
        value.split(whereSeparator: { "、,/".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// "원어 -> 번역어" pairs from a plain-text glossary.
    private var arrowLinePairs: [(String, String)] {
        var pairs: [(String, String)] = []
        for rawLine in translationGlossaryText.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let range = line.range(of: "->") ?? line.range(of: "→") else { continue }
            let source = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let target = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !source.isEmpty, !target.isEmpty { pairs.append((source, target)) }
        }
        return Array(pairs.prefix(500))
    }

    /// Entry count for the settings UI, format-agnostic.
    var translationGlossaryCount: Int {
        if let entries = translationGlossaryJSON { return entries.count }
        return arrowLinePairs.count
    }

    /// LLM refinement is usable only when enabled and minimally configured.
    /// The ChatGPT subscription provider authenticates via OAuth, not an API key.
    var llmConfigured: Bool {
        if llmProtocol == .chatgpt {
            return ChatGPTOAuth.shared.isSignedIn &&
                !llmModel.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return !llmBaseURL.trimmingCharacters(in: .whitespaces).isEmpty &&
        !llmAPIKey.trimmingCharacters(in: .whitespaces).isEmpty &&
        !llmModel.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
