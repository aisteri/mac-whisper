import Cocoa
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let fnMonitor = FnKeyMonitor()
    private let speech = SpeechService()
    /// Long-form engine (SpeechAnalyzer) used only for locked recordings, where
    /// long silences are normal and SFSpeechRecognizer's dictation model breaks.
    private let longForm = LongFormTranscriber()
    /// Live utterance-by-utterance translation for the interpreter mode.
    private let translator = TranslationEngine()
    /// Voices translated utterances (continuous TTS with optional ducking).
    private let speechOutput = SpeechOutput()
    /// Decides when streamed translations are settled enough to speak —
    /// including ahead of DeepL's conclusion (see SpeechGate).
    private let speechGate = SpeechGate()
    /// On-device translation backend (Apple Translation framework).
    private let appleTranslator = AppleTranslator()

    // MARK: DeepL Voice streaming state
    //
    /// Active streaming session (nil outside voice-mode recordings).
    private var voiceSession: DeepLVoiceSession?
    /// Transcript carried over across session reconnects (1 h server cap,
    /// network drops): the new session's text is appended onto these bases.
    private var voiceSourceBase = ""
    private var voiceTargetBase = ""
    /// Latest full transcripts (base + current session), for save/display.
    private var voiceSourceFull = ""
    private var voiceTargetFull = ""
    /// What the gate has actually sent to the voice — the caption source in
    /// gate-driven modes, so screen and speech always agree.
    private var voiceSpokenCaption = ""
    /// True while the speech gate owns the captions (DeepL Voice and Apple
    /// interpreter sessions); the LLM path keeps grey/white agreement runs.
    private var gateDrivesCaptions = false
    private var voiceRestarts = 0

    /// What a locked session is for: a meeting capture (transcript + optional
    /// refinement/minutes) or one-way live interpretation (translated captions;
    /// only the raw conversation is saved — never minutes).
    private enum LockMode { case meeting, interpreter }
    private var lockMode: LockMode = .meeting

    private let panel = FloatingPanel()
    private let transcriptWindow = TranscriptWindowController()
    private let subtitles = SubtitleOverlay()
    private let settingsController = SettingsWindowController()
    private let permissionsController = PermissionsWindowController()

    private var isRecording = false
    private var isFinishing = false

    /// Locked (hands-free) recording: started with a quick double-tap of Fn or
    /// from the menu, ended with a single Fn tap. The transcript is written to a
    /// file instead of pasted, so long captures never touch the clipboard.
    private var isLockedRecording = false
    /// When the current locked session started (guards instant re-toggle).
    private var lockStartedAt = Date.distantPast
    /// True between the stop gesture and the session's final delivery, so
    /// extra presses while the transcript drains can't retrigger anything.
    private var lockStopping = false

    /// What the current Fn hold resolved to. Modifiers are re-checked while Fn
    /// is held (see evaluateFnHold), so Ctrl/Shift may be pressed before or
    /// after Fn in any order.
    private enum FnHoldAction { case undecided, pushToTalk, lockToggle }
    private var fnHoldAction: FnHoldAction = .undecided
    private var fnHoldTimer: Timer?
    private var fnHoldStartedAt = Date.distantPast
    /// When Ctrl (without Shift) was first seen during this hold — start of
    /// the Shift-detection delay.
    private var ctrlOnlySince: Date?
    /// Keeps the system awake during a locked recording session.
    private var sleepActivity: NSObjectProtocol?
    /// Timestamp naming the current locked session's output files.
    private var lockSessionStamp: String?
    /// In-progress transcript autosave for the locked session (crash recovery).
    private var lockAutosaveURL: URL?
    private var lastAutosaveAt = Date.distantPast

    private let settings = Settings.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.migrateFlatLayout()
        setupEditMenu()
        setupStatusItem()
        requestPermissionsAndStart()
        wireSpeech()
    }

    /// A menu-bar app has no visible main menu — but without one, ⌘C/⌘V/⌘X
    /// reach no responder and every text field beeps at paste. Install an
    /// invisible Edit menu so the standard shortcuts work in Settings fields.
    private func setupEditMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Undo any output mute/duck and restore the user's original input
        // device that we switched to the built-in mic while the app ran.
        SystemAudio.restoreOutput()
        SystemAudio.unduckOutput()
        SystemAudio.restoreInput()
    }

    // MARK: - Status bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Remember the item's menu-bar position across launches.
        statusItem.autosaveName = "MacTranscribeStatusItem"
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Mac Transcribe")
            button.image?.isTemplate = true
        }
        rebuildMenu()
        // Diagnose "icon not visible" reports: log where the item actually landed
        // (an x past the notch's left edge means macOS hid it behind the notch).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let button = self.statusItem.button, let window = button.window else {
                NSLog("MacTranscribe[App]: status item has no window (not visible)")
                return
            }
            let frame = window.frame
            let screen = NSScreen.main?.frame ?? .zero
            NSLog("MacTranscribe[App]: status item frame=\(frame) screen=\(screen) visible=\(self.statusItem.isVisible)")
            let line = "\(Date()) statusItem x=\(Int(frame.origin.x)) y=\(Int(frame.origin.y)) w=\(Int(frame.width)) screenW=\(Int(screen.width)) visible=\(self.statusItem.isVisible)\n"
            if let data = line.data(using: .utf8) {
                if let handle = FileHandle(forWritingAtPath: "/tmp/macwhisper-diag.log") {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                } else {
                    try? data.write(to: URL(fileURLWithPath: "/tmp/macwhisper-diag.log"))
                }
            }
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let header = NSMenuItem(title: "Hold Fn to talk", action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.attributedTitle = holdToTalkTitle()
        menu.addItem(header)
        menu.addItem(.separator())

        // Core action: start/stop a locked (hands-free) recording — saved to
        // ~/Documents/MacTranscribe. Everything configurable lives in Settings.
        let lockTitle = isLockedRecording ? "Stop Recording & Save" : "Start Recording"
        let lockItem = NSMenuItem(title: lockTitle, action: #selector(toggleLockedRecording), keyEquivalent: "")
        lockItem.target = self
        lockItem.image = menuIcon(isLockedRecording ? "stop.circle" : "record.circle")
        menu.addItem(lockItem)

        // Live Translation is toggled often enough per-session to earn a
        // shortcut here; source/target languages live in Settings ▸ Translation.
        let interpItem = NSMenuItem(title: "Live Translation", action: #selector(toggleLiveTranslation), keyEquivalent: "")
        interpItem.target = self
        interpItem.image = settings.liveTranslationEnabled ? menuIcon("checkmark") : nil
        menu.addItem(interpItem)

        let windowItem = NSMenuItem(title: "Transcript Window…", action: #selector(openTranscriptWindow), keyEquivalent: "")
        windowItem.target = self
        windowItem.image = menuIcon("text.rectangle.page")
        menu.addItem(windowItem)

        let folderItem = NSMenuItem(title: "Open Saved Folder", action: #selector(openSavedFolder), keyEquivalent: "")
        folderItem.target = self
        folderItem.image = menuIcon("folder")
        menu.addItem(folderItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = menuIcon("gearshape")
        menu.addItem(settingsItem)

        let permItem = NSMenuItem(title: "Permissions…", action: #selector(openPermissions), keyEquivalent: "")
        permItem.target = self
        permItem.image = menuIcon("lock.shield")
        menu.addItem(permItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        quit.keyEquivalentModifierMask = [.command]
        menu.addItem(quit)

        // Reflect the locked-recording state in the menu-bar icon so a running
        // capture is visible even with no HUD and the window closed.
        if let button = statusItem.button {
            let symbol = isLockedRecording ? "record.circle" : "mic.fill"
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Mac Transcribe")
            button.image?.isTemplate = true
        }

        statusItem.menu = menu
    }

    /// Builds the "Hold 🌐 to talk" header title, rendering the Fn key as the
    /// Apple Globe/Fn key glyph (SF Symbol "globe").
    private func holdToTalkTitle() -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let result = NSMutableAttributedString(string: "Hold ⌃", attributes: textAttrs)

        if let globe = NSImage(systemSymbolName: "globe", accessibilityDescription: "Fn")?
            .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .regular)) {
            globe.isTemplate = true
            let attachment = NSTextAttachment()
            attachment.image = globe
            let size = globe.size
            // Align the glyph baseline with the surrounding text.
            attachment.bounds = NSRect(x: 0, y: font.descender, width: size.width, height: size.height)
            result.append(NSAttributedString(attachment: attachment))
        } else {
            result.append(NSAttributedString(string: "Fn", attributes: textAttrs))
        }

        result.append(NSAttributedString(string: " to talk", attributes: textAttrs))
        return result
    }

    /// Builds a small template menu icon from an SF Symbol, sized to align with
    /// the menu text. Template images are tinted by AppKit for light/dark mode.
    private func menuIcon(_ symbol: String) -> NSImage? {
        let pointSize = NSFont.menuFont(ofSize: 0).pointSize
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
        image?.isTemplate = true
        return image
    }

    // MARK: - Permissions + monitor

    private func requestPermissionsAndStart() {
        fnMonitor.customTrigger = settings.triggerKey
        fnMonitor.longTrigger = settings.longTriggerKey
        _ = fnMonitor.start()
        fnMonitor.onFnDown = { [weak self] at, source in self?.handleFnDown(at: at, source: source) }
        fnMonitor.onFnUp = { [weak self] at in self?.handleFnUp(at: at) }
        fnMonitor.onComboKeyWhileFnHeld = { [weak self] in self?.handleFnCombo() }
        fnMonitor.onLongTriggerDown = { [weak self] in
            SpeechService.diag("long trigger key -> toggle locked")
            self?.toggleLockHotkey()
        }
        settingsController.fnMonitor = fnMonitor
        settingsController.onTriggerChanged = { [weak self] in
            guard let self else { return }
            self.fnMonitor.customTrigger = self.settings.triggerKey
            self.fnMonitor.longTrigger = self.settings.longTriggerKey
        }
        // Non-Engine settings persist immediately; apply the ones a running
        // session or the menu bar cares about, then rebuild the menu.
        settingsController.onSettingsChanged = { [weak self] in
            guard let self else { return }
            self.translator.targetLanguage = self.settings.interpreterTargetLanguage
            self.translator.sourceLanguage = self.settings.interpreterSourceLanguage
            if self.isLockedRecording {
                if self.settings.subtitleOverlayEnabled { self.subtitles.show() }
                else { self.subtitles.hide() }
            }
            self.rebuildMenu()
        }

        // Live-restart the Fn monitor the moment Input Monitoring is granted
        // while the permissions window is open, so the Fn key starts working
        // without an app restart (the Codex "Quit & Reopen" step avoided).
        permissionsController.onInputMonitoringGranted = { [weak self] in
            self?.fnMonitor.stop()
            _ = self?.fnMonitor.start()
        }

        // Show the single combined permissions window only when something is missing.
        if !PermissionsWindowController.allGranted {
            permissionsController.showWindow()
        }
    }

    private func wireSpeech() {
        speech.onLevel = { [weak self] level in self?.panel.updateLevel(level) }
        speech.onTranscript = { [weak self] text in
            self?.panel.updateText(text)
            self?.autosaveLockedTranscript(text)
        }
        speech.onFinished = { [weak self] text in self?.handleFinalTranscript(text) }
        // Silence auto-stop (VAD) ends the session via the same path as Fn-release.
        speech.onAutoStop = { [weak self] in self?.stopRecording() }

        // Locked (long-form) sessions render into the transcript window — a
        // normal draggable/resizable window — instead of the floating HUD.
        longForm.onTranscript = { [weak self] text, stableLength in
            guard let self else { return }
            if self.lockMode == .interpreter {
                // The translation engine renders the display; the autosave
                // still keeps the raw original.
                self.translator.feed(text, stableLength: stableLength)
            } else {
                self.transcriptWindow.updateTranscript(text)
                self.subtitles.update(fullText: text)
            }
            self.autosaveLockedTranscript(text)
        }
        translator.onDisplay = { [weak self] transcript, caption in
            guard let self else { return }
            self.transcriptWindow.updateTranscript(transcript)
            // Committed words render white, the still-moving hypothesis (or an
            // untranslated line's source fallback) dimmed. In gate mode the
            // captions follow the SPOKEN stream instead (appendVoiceCaption)
            // — no flickering grey, screen matches the voice.
            if !self.gateDrivesCaptions {
                self.subtitles.update(pieces: caption.map { ($0.text, $0.committed) })
            }
        }
        translator.onSpeakableTranslation = { [weak self] text in
            self?.speechOutput.enqueue(text)
        }
        speechGate.speak = { [weak self] text in
            guard let self else { return }
            self.speechOutput.enqueue(text)
            // With TTS off there is no playback to key the captions to —
            // show the settled text as soon as the gate clears it.
            if !self.speechOutput.enabled {
                self.appendVoiceCaption(text)
            }
        }
        // DeepL streaming mode: the caption IS the spoken stream, keyed to
        // PLAYBACK — screen and voice always agree, and when the voice
        // falls behind, the captions wait with it instead of scrolling the
        // still-unspoken text away.
        speechOutput.onPlaybackReached = { [weak self] text in
            self?.appendVoiceCaption(text)
        }
        // Captions must never idle-fade while the voice is mid-sentence:
        // their content clock only ticks when a sentence STARTS playing.
        subtitles.isBusy = { [weak self] in
            self?.speechOutput.isSpeaking ?? false
        }
        longForm.onFinished = { [weak self] text in self?.handleLockedFinished(text) }
        longForm.onStatus = { [weak self] status in
            self?.transcriptWindow.setStatus(status)
            self?.subtitles.flashStatus(status)
        }
        transcriptWindow.onStopRequested = { [weak self] in self?.stopLockedRecording() }
        // Closing the subtitles hides them for this session only; the recording
        // itself keeps running.
        subtitles.onCloseRequested = { }
    }

    // MARK: - Recording cycle

    /// How long a ⌃Fn press waits for a possible Shift before starting
    /// push-to-talk. Users aiming for ⌃⇧Fn may land Shift a beat after Fn;
    /// without this delay that would misfire a short dictation session.
    private static let shiftDetectionDelay: TimeInterval = 0.15
    /// Ignore the lock hotkey again for this long after locking, so holding
    /// the combo a beat too long can't immediately stop the new session.
    private static let lockToggleGrace: TimeInterval = 1.5

    /// How long after Fn goes down we keep watching for Ctrl/Shift to arrive.
    /// Modifiers may be pressed in any order; past this window a bare Fn hold
    /// is just the system Globe key and we stand down.
    private static let modifierArrivalWindow: TimeInterval = 1.0

    /// Which trigger key started the current hold. The Apple Fn requires Ctrl
    /// (⌃Fn); a custom trigger key (Right Ctrl by default) fires on its own.
    private var fnHoldSource: FnKeyMonitor.TriggerSource = .appleFn

    private func handleFnDown(at now: Date, source: FnKeyMonitor.TriggerSource) {
        SpeechService.diag("trigger down source=\(source) locked=\(isLockedRecording)")
        fnHoldAction = .undecided
        fnHoldSource = source
        ctrlOnlySince = nil
        fnHoldStartedAt = now
        // Evaluate immediately (modifiers already down), then keep polling
        // while Fn is held so Ctrl/Shift pressed *after* Fn still trigger.
        evaluateFnHold()
        guard fnHoldAction == .undecided else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.evaluateFnHold()
        }
        RunLoop.main.add(timer, forMode: .common)
        fnHoldTimer = timer
    }

    private func stopFnHoldTimer() {
        fnHoldTimer?.invalidate()
        fnHoldTimer = nil
    }

    private func evaluateFnHold() {
        guard fnHoldAction == .undecided else {
            stopFnHoldTimer()
            return
        }
        let mods = NSEvent.modifierFlags
        // The Apple Fn key needs Ctrl held (⌃Fn); a custom trigger chord fires
        // when all of its required modifiers are held with it.
        let chord = settings.triggerKey
        let baseSatisfied = fnHoldSource == .custom
            ? FnKeyMonitor.modifiersSatisfied(chord)
            : mods.contains(.control)
        // The +Shift lock upgrade only applies when Shift is not already part
        // of the chord itself (otherwise dictation would be unreachable).
        let shiftUpgrades = fnHoldSource == .appleFn || !chord.modifiers.contains(.shift)

        // Trigger+Shift: toggle locked (long-form) recording.
        if baseSatisfied && shiftUpgrades && mods.contains(.shift) {
            fnHoldAction = .lockToggle
            stopFnHoldTimer()
            SpeechService.diag("trigger+shift -> toggle locked (locked=\(isLockedRecording))")
            toggleLockHotkey()
            return
        }

        // Trigger alone: push-to-talk — held through the Shift-detection delay
        // first so a Shift landing a beat later upgrades to the lock toggle
        // instead of misfiring a dictation session.
        if baseSatisfied {
            if ctrlOnlySince == nil { ctrlOnlySince = Date() }
            if Date().timeIntervalSince(ctrlOnlySince!) >= Self.shiftDetectionDelay {
                stopFnHoldTimer()
                guard !isLockedRecording else { return }
                fnHoldAction = .pushToTalk
                startRecording()
            }
            return
        }

        // Ctrl was released (or never pressed) — reset the delay clock and
        // give up once the arrival window passes: it's a bare Fn / Globe use.
        ctrlOnlySince = nil
        if Date().timeIntervalSince(fnHoldStartedAt) > Self.modifierArrivalWindow {
            stopFnHoldTimer()
        }
    }

    private func toggleLockHotkey() {
        if isLockedRecording {
            guard !lockStopping else { return }
            guard Date().timeIntervalSince(lockStartedAt) > Self.lockToggleGrace else { return }
            stopLockedRecording()
        } else {
            startLockedRecording()
        }
    }

    /// The user pressed another key while holding Fn — Fn is acting as a
    /// modifier (Fn+arrows, Fn+Backspace, F-keys…). Cancel any push-to-talk
    /// that misfired from ⌃Fn overlapping the combo.
    private var fnComboActive = false
    private func handleFnCombo() {
        guard !fnComboActive else { return }
        fnComboActive = true
        stopFnHoldTimer()
        let wasPushToTalk = fnHoldAction == .pushToTalk
        fnHoldAction = .lockToggle // sentinel: nothing more may start this hold
        // A locked recording must survive Fn combos untouched.
        guard !isLockedRecording, wasPushToTalk, isRecording || isFinishing else { return }
        NSLog("MacTranscribe[App]: Fn combo detected — canceling push-to-talk")
        SpeechService.diag("fn combo -> push-to-talk canceled")
        speech.cancel()
        isRecording = false
        isFinishing = false
        SystemAudio.restoreOutput()
        panel.hide()
    }

    private func handleFnUp(at now: Date) {
        fnComboActive = false
        stopFnHoldTimer()
        let action = fnHoldAction
        fnHoldAction = .undecided
        ctrlOnlySince = nil
        // Only a push-to-talk hold ends on Fn release; a locked session keeps
        // running, and an undecided hold never started anything.
        guard action == .pushToTalk, !isLockedRecording else { return }
        stopRecording()
    }

    // MARK: - Locked (hands-free) recording

    private func startLockedRecording() {
        guard !isLockedRecording else { return }
        // The Live Translation toggle is the master switch; the Engine tab's
        // Translation provider decides who does the work and what "ready"
        // means (Apple: nothing at all; DeepL: its API key; LLM: the
        // Meeting account).
        let providerReady = settings.appleTranslationEnabled
            || (settings.deeplEnabled && settings.deeplConfigured)
            || (!settings.deeplEnabled && settings.llmConfigured)
        let translationReady = settings.liveTranslationEnabled && providerReady
        let mode: LockMode = translationReady ? .interpreter : .meeting
        // Clear any streaming-mode residue from the previous session; the
        // voice branch below re-arms it when applicable.
        longForm.bypassAnalyzer = false
        longForm.externalAudioSink = nil
        voiceSession = nil
        gateDrivesCaptions = false
        lockMode = mode
        if mode == .interpreter {
            translator.reset()
            translator.onSpeechStreams = nil
            speechOutput.reset()
            speechOutput.enabled = settings.speakTranslations
            speechOutput.duckOthers = settings.duckWhileSpeaking
            speechOutput.languageTag = SpeechOutput.languageTag(
                deepl: settings.deeplEnabled ? settings.deeplTargetLang : "",
                llm: settings.interpreterTargetLanguage)
            speechOutput.voiceIdentifier = settings.speechVoiceIdentifier
            // Premium voices load their model on first synthesis; pay that
            // during session prep, not on the first translation.
            speechOutput.prewarm()
            // Duck for the WHOLE session: per-sentence duck/unduck swung
            // both the original and the voice (which rides the same system
            // volume) up and down through every gap.
            if settings.speakTranslations && settings.duckWhileSpeaking {
                SystemAudio.duckOutput(to: SpeechOutput.duckFactor)
            }
            speechGate.reset()
            // Early speech suits DeepL only: its tentative is the SAME
            // pipeline's earlier draft. The Apple path re-translates a
            // moving transcript hypothesis, so its live line rewrites
            // wholesale — early-speaking it produced triple readings
            // (measured). Apple speaks concluded translations only.
            speechGate.earlySpeech = settings.earlySpeechEnabled
                && !settings.appleTranslationEnabled
            voiceSpokenCaption = ""
            // The gate drives speech AND captions for the stream-shaped
            // providers (DeepL Voice, Apple); the LLM path keeps the legacy
            // per-utterance hand-off and grey/white captions.
            gateDrivesCaptions = settings.appleTranslationEnabled || settings.deeplVoiceEnabled
            translator.appleTranslator = nil
            if settings.appleTranslationEnabled {
                // On-device path: by construction NO network request is made
                // for translation — no LLM warm-up, no DeepL session, nothing.
                translator.useDeepL = false
                translator.targetLanguage = settings.interpreterTargetLanguage
                translator.sourceLanguage = settings.interpreterSourceLanguage
                translator.appleTranslator = appleTranslator
                // Same gate as DeepL Voice: clause-level early speech from
                // the live line, ledger dedup, playback-synced captions.
                translator.onSpeechStreams = { [weak self] concluded, tentative in
                    self?.speechGate.update(concludedStream: concluded, tentative: tentative)
                }
                let source = AppleTranslator.localeLanguage(forPrompt: settings.interpreterSourceLanguage)
                let target = AppleTranslator.localeLanguage(forPrompt: settings.interpreterTargetLanguage)
                    ?? Locale.Language(identifier: "en")
                appleTranslator.start(source: source, target: target) { [weak self] ready in
                    guard let self, !ready else { return }
                    self.transcriptWindow.setStatus("On-device translation unavailable for this pair — captions show the original")
                }
            } else if settings.deeplEnabled && settings.deeplConfigured && settings.deeplVoiceEnabled {
                // DeepL Voice streaming: audio goes straight to DeepL, which
                // does its own ASR + segmentation + translation. The local
                // recognizer never starts, so none of its fragment/ending
                // problems apply.
                voiceSourceBase = ""; voiceTargetBase = ""
                voiceSourceFull = ""; voiceTargetFull = ""
                voiceRestarts = 0
                longForm.bypassAnalyzer = true
                startVoiceSession()
            } else if settings.deeplEnabled && settings.deeplConfigured {
                translator.useDeepL = true
                translator.deeplAPIKey = settings.deeplAPIKey
                translator.deeplTargetLang = settings.deeplTargetLang
                translator.deeplSourceLang = settings.deeplSourceLang
            } else {
                translator.useDeepL = false
                translator.targetLanguage = settings.interpreterTargetLanguage
                translator.sourceLanguage = settings.interpreterSourceLanguage
                // Pre-warm the LLM path (token refresh, instructions cache, TLS)
                // so the first real utterance doesn't pay for any of it.
                LLMRefiner.warmUpTranslation(to: settings.interpreterTargetLanguage)
            }
        }
        // Interpreter captions run taller (three lines of continuity: a
        // translation trails its speech, so the surrounding lines keep it
        // readable). Idle-fade is on for BOTH modes now: interpreter
        // captions follow the spoken stream, so nothing arrives late to
        // replace a displayed line anymore — when the voice goes quiet,
        // the caption panel should clear like any broadcast subtitle.
        subtitles.maxLines = mode == .interpreter ? 3 : 2
        subtitles.fadeWhenIdle = true
        // Translation sessions have their own audio-source setting (a call
        // being interpreted usually plays through the system; a meeting is
        // usually the room mic).
        let useSystemAudio = mode == .interpreter
            ? settings.translationAudioSourceIsSystem
            : settings.lockedAudioSourceIsSystem
        longForm.audioSource = useSystemAudio ? .systemAudio : .microphone
        NSLog("MacTranscribe[App]: locked recording started mode=\(mode)")
        // Tear down the short push-to-talk session left over from the
        // double-tap's first tap; the locked session uses the long-form engine.
        // cancel() suppresses that session's onFinished on purpose, which also
        // suppresses the HUD dismissal that normally rides on it — so hide the
        // HUD explicitly or it lingers on screen for the whole locked session.
        if isRecording || isFinishing {
            speech.cancel()
            isRecording = false
            isFinishing = false
        }
        panel.hide()
        isLockedRecording = true
        lockStartedAt = Date()
        lockStopping = false
        stopFnHoldTimer()
        // Belt-and-suspenders for long captures: back up the raw audio and
        // autosave the partial transcript so neither a recognition failure nor
        // a crash can silently lose the recording.
        let stamp = Self.fileTimestamp()
        lockSessionStamp = stamp
        try? FileManager.default.createDirectory(at: Self.recordingsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: Self.transcriptsDirectory, withIntermediateDirectories: true)
        longForm.audioBackupURL = Self.recordingsDirectory.appendingPathComponent("recording-\(stamp).m4a")
        lockAutosaveURL = Self.transcriptsDirectory.appendingPathComponent(".inprogress-\(stamp).txt")
        lastAutosaveAt = .distantPast
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "MacTranscribe locked recording")
        // Note: unlike push-to-talk, locked recording does NOT mute the system
        // output — meeting audio must stay audible, and the mute was silencing
        // the start-feedback sound itself.
        // No floating HUD for locked sessions — the transcript window (opened
        // from the menu) and the menu-bar icon carry the feedback.
        transcriptWindow.updateTranscript("")
        let interpLabel: String
        // The ACTIVE provider's target — the DeepL paths translate into
        // deeplTargetLang; interpreterTargetLanguage belongs to the LLM and
        // Apple paths and may hold a stale value from a provider switch.
        let usesDeepL = longForm.bypassAnalyzer || translator.useDeepL
        let targetName = usesDeepL
            ? (DeepLTranslator.targetLanguages.first { $0.code == settings.deeplTargetLang }?.display
               ?? settings.deeplTargetLang)
            : settings.interpreterTargetLanguage
        if mode == .interpreter {
            let via = longForm.bypassAnalyzer ? "DeepL Voice"
                : translator.appleTranslator != nil ? "Apple (on-device)"
                : translator.useDeepL ? "DeepL" : "LLM"
            interpLabel = "● Interpreting → \(targetName) via \(via)…"
        } else {
            interpLabel = "● Recording…  (⌃⇧Fn to stop)"
        }
        transcriptWindow.setStatus(interpLabel)
        transcriptWindow.setRecording(true)
        if settings.subtitleOverlayEnabled {
            subtitles.show()
        }
        // Immediate start feedback: without it users assume the toggle didn't
        // register and press again, which stops the recording they just began.
        NSSound(named: "Pop")?.play()
        subtitles.flashStatus(mode == .interpreter
            ? "● 통역 시작 → \(targetName)"
            : "● 녹음 시작")
        longForm.start(language: settings.language)
        rebuildMenu()
    }

    private func stopLockedRecording() {
        guard isLockedRecording, !lockStopping else { return }
        lockStopping = true
        NSLog("MacTranscribe[App]: locked recording stopping")
        NSSound(named: "Bottle")?.play()
        subtitles.flashStatus("■ 녹음 종료 — 저장 중…")
        transcriptWindow.setStatus("Finishing…")
        longForm.stop()
    }

    /// Final delivery for a locked session (long-form engine). Locked captures
    /// are persisted to a file, never the clipboard.
    private func handleLockedFinished(_ text: String) {
        guard isLockedRecording else { return }
        isLockedRecording = false
        lockStopping = false
        // Keep the sleep-prevention activity alive: meeting notes and
        // transcript refinement run after the recording ends, and closing
        // the lid mid-generation kills the network request. The activity
        // is released by endPostRecordingActivity() when all post-processing
        // finishes (or immediately when none is needed).
        transcriptWindow.setRecording(false)
        subtitles.hide()
        translator.teardown()
        appleTranslator.stop()
        speechOutput.endSession()
        SystemAudio.unduckOutput() // session-scoped duck ends with the session
        // Streaming mode: the voice session owns the transcript (the local
        // recognizer never ran); stop it and save what it heard.
        var finalText = text
        if longForm.bypassAnalyzer {
            voiceSession?.stop()
            voiceSession = nil
            longForm.externalAudioSink = nil
            longForm.bypassAnalyzer = false
            finalText = voiceSourceFull
        }
        postRecordingTasks = 0
        finishLockedSession(with: finalText)
        // If no post-recording tasks were started (no refinement, no notes),
        // release the sleep-prevention activity now; otherwise each task
        // releases it when it finishes.
        if postRecordingTasks == 0 {
            if let activity = sleepActivity {
                ProcessInfo.processInfo.endActivity(activity)
                sleepActivity = nil
            }
        }
        rebuildMenu()
    }

    /// How many post-recording tasks (refinement, meeting notes) are still
    /// running. The sleep-prevention activity stays alive until this hits 0.
    private var postRecordingTasks = 0

    private func beginPostRecordingTask() { postRecordingTasks += 1 }

    private func endPostRecordingTask() {
        postRecordingTasks = max(0, postRecordingTasks - 1)
        if postRecordingTasks == 0 {
            if let activity = sleepActivity {
                ProcessInfo.processInfo.endActivity(activity)
                sleepActivity = nil
            }
        }
    }

    private func startRecording() {
        NSLog("MacTranscribe[App]: startRecording isRecording=\(isRecording) isFinishing=\(isFinishing)")
        // A rapid Fn press during the previous session's flush window (between
        // stop() and the recognizer's onFinished) used to be rejected by the
        // isFinishing guard, dropping the press — and the stale session's
        // deferred panel.hide() then dismissed the HUD mid-sequence. Supersede
        // the finishing session instead: hard-cancel it (no transcript injected
        // for the aborted session) and start fresh. speech.cancel() invalidates
        // every stale async finish() via the generation token, so the late
        // onFinished from the old session can't tear down the new one.
        if isFinishing {
            NSLog("MacTranscribe[App]: superseding finishing session")
            speech.cancel()
            isFinishing = false
        }
        guard !isRecording else { return }
        isRecording = true
        SystemAudio.muteOutput()
        speech.reset()
        // Apply the current silence auto-stop preference for this session.
        speech.silenceAutoStopEnabled = settings.silenceAutoStopEnabled
        // Re-read the glossary each session so edits apply without a restart.
        speech.contextualStrings = settings.glossaryTerms
        panel.show(placeholder: settings.language.listeningPlaceholder)
        speech.start(language: settings.language)
    }

    private func stopRecording() {
        NSLog("MacTranscribe[App]: stopRecording isRecording=\(isRecording)")
        SystemAudio.restoreOutput()
        guard isRecording else { return }
        isRecording = false
        isFinishing = true
        speech.stop()
    }

    private func handleFinalTranscript(_ text: String) {
        // Accept the final whenever a session is active — whether it ended via
        // Fn-release, VAD auto-stop, or an unexpected recognizer end — and clear
        // both flags so the HUD always dismisses and we ignore any duplicate.
        guard isRecording || isFinishing else { return }
        isRecording = false
        isFinishing = false

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            finish(with: "")
            return
        }

        if settings.llmEnabled && settings.llmConfigured {
            panel.showStatus("Refining…")
            LLMRefiner.refine(trimmed) { [weak self] result in
                DispatchQueue.main.async {
                    let output: String
                    switch result {
                    case .success(let refined): output = refined
                    case .failure: output = trimmed // fall back to raw transcript
                    }
                    self?.finish(with: output)
                }
            }
        } else {
            finish(with: trimmed)
        }
    }

    private func finish(with text: String) {
        isFinishing = false
        panel.hide {
            if !text.isEmpty {
                TextInjector.inject(text)
            }
        }
    }

    // MARK: - DeepL Voice streaming

    /// Opens a streaming session and points the capture tee at it. Called at
    /// session start and again on reconnect (server 1 h cap, network drops);
    /// the finished transcript of the dying session is folded into the base
    /// so the display and the save never lose text across reconnects.
    private func startVoiceSession() {
        let session = DeepLVoiceSession()
        voiceSession = session
        session.onSourceTranscript = { [weak self] concluded, tentative in
            guard let self, self.voiceSession === session else { return }
            self.voiceSourceFull = self.voiceSourceBase + concluded + tentative
            self.autosaveLockedTranscript(self.voiceSourceFull)
        }
        session.onTargetTranscript = { [weak self] concluded, tentative in
            guard let self, self.voiceSession === session else { return }
            // Receiving translations proves the connection is healthy —
            // reset the reconnect budget so only CONSECUTIVE failures spend it.
            self.voiceRestarts = 0
            self.voiceTargetFull = self.voiceTargetBase + concluded
            self.transcriptWindow.updateTranscript(self.voiceTargetFull + tentative)
            // The captions are NOT drawn here: they follow the gate's speak
            // stream (below), so the screen shows exactly what the voice
            // says — no flickering provisional text that a conclusion will
            // rewrite anyway.
            // The gate decides what is settled enough to speak — concluded
            // text always, plus stable tentative sentences/clauses ahead of
            // their conclusion. The concluded stream survives reconnects
            // via the base, so its char counts never go stale.
            self.speechGate.update(concludedStream: self.voiceTargetFull, tentative: tentative)
        }
        session.onError = { [weak self] message in
            self?.handleVoiceError(message, from: session)
        }
        // Hook the audio first — the session buffers pre-connection audio,
        // so nothing is lost while the glossary/session request runs.
        longForm.externalAudioSink = { [weak session] buffer in
            session?.feed(buffer)
        }
        let apiKey = settings.deeplAPIKey
        let sourceLang = settings.deeplSourceLang
        let targetLang = settings.deeplTargetLang
        let launch: (String?) -> Void = { [weak self, weak session] glossaryID in
            guard let self, let session, self.voiceSession === session else { return }
            session.start(apiKey: apiKey, sourceLang: sourceLang,
                          targetLang: targetLang, glossaryID: glossaryID)
        }
        // Glossary terms ride along when the language pair maps onto the
        // terminology sheet's columns and the source language is fixed
        // (DeepL glossaries are per language pair).
        let pairs = Settings.glossaryColumn(deepl: targetLang).map {
            settings.translationGlossaryPairs(
                sourceColumn: Settings.glossaryColumn(deepl: sourceLang),
                targetColumn: $0)
        } ?? []
        if pairs.isEmpty || sourceLang.isEmpty {
            launch(nil)
        } else {
            DeepLTranslator.ensureGlossary(
                apiKey: apiKey, sourceLang: sourceLang, targetLang: targetLang,
                entries: pairs
            ) { glossaryID in
                DispatchQueue.main.async { launch(glossaryID) }
            }
        }
    }

    /// Appends spoken (or gate-settled, when TTS is off) text to the
    /// streaming-mode caption and redraws it.
    private func appendVoiceCaption(_ text: String) {
        guard gateDrivesCaptions else { return }
        voiceSpokenCaption += voiceSpokenCaption.isEmpty ? text : " " + text
        if voiceSpokenCaption.count > 2000 {
            voiceSpokenCaption = String(voiceSpokenCaption.suffix(1000))
        }
        subtitles.update(pieces: Self.voiceCaptionPieces(
            concluded: voiceSpokenCaption, tentative: ""))
    }

    private func handleVoiceError(_ message: String, from session: DeepLVoiceSession) {
        guard voiceSession === session, isLockedRecording, longForm.bypassAnalyzer else { return }
        // Fold the dead session's text into the base and reconnect.
        voiceSourceBase = voiceSourceFull.isEmpty ? "" : voiceSourceFull + "\n"
        voiceTargetBase = voiceTargetFull.isEmpty ? "" : voiceTargetFull + "\n"
        // The dead session's tentative text will never conclude; write off
        // anything spoken ahead of it. Concluded accounting stays valid —
        // the base folding above keeps that stream append-only.
        speechGate.tentativeInvalidated()
        guard voiceRestarts < 5 else {
            transcriptWindow.setStatus("Voice session lost (\(message)) — recording continues, translation stopped")
            subtitles.flashStatus("⚠️ 통역 연결 끊김 — 녹음은 계속됩니다")
            return
        }
        voiceRestarts += 1
        NSLog("MacTranscribe[App]: voice session error (\(message)); reconnect #\(voiceRestarts)")
        transcriptWindow.setStatus("Voice reconnecting (\(voiceRestarts))…")
        // Brief backoff so a hard outage doesn't burn the budget instantly;
        // stale audio accumulated meanwhile is dropped by the session itself.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.isLockedRecording, self.longForm.bypassAnalyzer else { return }
            self.startVoiceSession()
        }
    }

    /// Caption pieces for streaming mode: the last couple of concluded
    /// sentences white, the tentative tail grey — same broadcast style as
    /// the engine-based path.
    private static func voiceCaptionPieces(concluded: String, tentative: String) -> [(text: String, isFinal: Bool)] {
        var sentences: [String] = []
        var current = ""
        for ch in concluded {
            current.append(ch)
            if "。.?？!！\n".contains(ch) {
                let t = current.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { sentences.append(t) }
                current = ""
            }
        }
        let leftover = current.trimmingCharacters(in: .whitespaces)
        var pieces: [(text: String, isFinal: Bool)] = []
        let tail = sentences.suffix(2).joined(separator: "\n")
        if !tail.isEmpty {
            pieces.append((tail + (leftover.isEmpty && tentative.isEmpty ? "" : "\n"), true))
        }
        if !leftover.isEmpty { pieces.append((leftover, true)) }
        if !tentative.isEmpty { pieces.append((tentative, false)) }
        return pieces
    }

    // MARK: - Locked session persistence

    /// ~/Documents/MacTranscribe — with transcripts, recordings, and notes
    /// in their own subfolders so a month of sessions stays browsable.
    static var baseDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacTranscribe", isDirectory: true)
    }
    static var transcriptsDirectory: URL { baseDirectory.appendingPathComponent("transcripts", isDirectory: true) }
    static var recordingsDirectory: URL { baseDirectory.appendingPathComponent("recordings", isDirectory: true) }
    static var notesDirectory: URL { baseDirectory.appendingPathComponent("notes", isDirectory: true) }

    /// One-time move of pre-split files from the flat layout into the
    /// subfolders. Runs at launch; already-moved files are untouched.
    static func migrateFlatLayout() {
        let fm = FileManager.default
        for dir in [transcriptsDirectory, recordingsDirectory, notesDirectory] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        guard let entries = try? fm.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil) else { return }
        for url in entries {
            let name = url.lastPathComponent
            let destDir: URL?
            if name.hasPrefix("transcript-") || name.hasPrefix(".inprogress-") {
                destDir = transcriptsDirectory
            } else if name.hasPrefix("recording-") {
                destDir = recordingsDirectory
            } else if name.hasPrefix("notes-") {
                destDir = notesDirectory
            } else {
                destDir = nil
            }
            if let destDir {
                try? fm.moveItem(at: url, to: destDir.appendingPathComponent(name))
            }
        }
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }

    /// "yyyy-MM-dd_HH-mm-ss" file stamp → "yyyy-MM-dd HH:mm" for the minutes'
    /// 일시 field.
    private static func meetingDateString(from stamp: String) -> String {
        let parts = stamp.split(separator: "_")
        guard parts.count == 2 else { return stamp }
        let time = parts[1].split(separator: "-")
        guard time.count >= 2 else { return String(parts[0]) }
        return "\(parts[0]) \(time[0]):\(time[1])"
    }

    /// Serial queue for transcript autosaves — atomic writes on the main
    /// thread would stutter the UI during long sessions.
    private let autosaveQueue = DispatchQueue(label: "macwhisper.autosave", qos: .utility)

    /// Continuously mirrors the locked session's partial transcript to disk so a
    /// crash or recognition failure can never lose more than ~2 seconds of text.
    private func autosaveLockedTranscript(_ text: String) {
        guard isLockedRecording, let url = lockAutosaveURL, !text.isEmpty else { return }
        let now = Date()
        guard now.timeIntervalSince(lastAutosaveAt) >= 2 else { return }
        lastAutosaveAt = now
        autosaveQueue.async {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Generates structured meeting notes from the raw transcript via the LLM
    /// (glossary included in the prompt) and saves them as notes-<stamp>.md.
    /// Failures only log — the transcript file is already safe on disk.
    private func generateMeetingNotes(from transcript: String, stamp: String) {
        beginPostRecordingTask()
        NSLog("MacTranscribe[App]: generating meeting notes chars=\(transcript.count)")
        SpeechService.diag("meeting notes generating chars=\(transcript.count)")
        // Minutes for a long meeting take a few minutes to write; without a
        // visible status users read the wait as "notes were never made" (and
        // may quit the app mid-generation, which really does lose them).
        let provider = settings.meetingNotesProvider
        let providerLabel = provider == "claude" ? "Claude" : "LLM"
        transcriptWindow.setStatus("Generating meeting notes via \(providerLabel)… (takes a few minutes; keep the app running)")
        let meetingDate = Self.meetingDateString(from: stamp)
        let handler: (Result<String, Error>) -> Void = { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let notes):
                    try? FileManager.default.createDirectory(at: Self.notesDirectory, withIntermediateDirectories: true)
                    let url = Self.notesDirectory.appendingPathComponent("notes-\(stamp).md")
                    do {
                        try notes.write(to: url, atomically: true, encoding: .utf8)
                        NSLog("MacTranscribe[App]: meeting notes saved chars=\(notes.count)")
                        SpeechService.diag("meeting notes saved -> \(url.lastPathComponent)")
                        self.transcriptWindow.setStatus("Meeting notes saved: \(url.lastPathComponent)")
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } catch {
                        NSLog("MacTranscribe[App]: failed to save meeting notes: \(error)")
                    }
                case .failure(let error):
                    NSLog("MacTranscribe[App]: meeting notes failed: \(error.localizedDescription)")
                    SpeechService.diag("meeting notes FAILED: \(error.localizedDescription)")
                    self.transcriptWindow.setStatus("Meeting notes failed — transcript is saved")
                }
                self.endPostRecordingTask()
            }
        }
        if provider == "claude" {
            LLMRefiner.generateMeetingNotesViaClaude(from: transcript, meetingDate: meetingDate, completion: handler)
        } else {
            LLMRefiner.generateMeetingNotes(from: transcript, meetingDate: meetingDate, completion: handler)
        }
    }

    /// Refines a saved long-form transcript with the configured LLM and updates
    /// the file in place. The raw text is already on disk, so any failure —
    /// network, quota, a bad chunk — simply leaves the original content.
    /// Long transcripts are refined in chunks to stay inside response limits.
    private func refineTranscriptFile(_ text: String, at url: URL) {
        beginPostRecordingTask()
        let chunks = Self.chunkForRefinement(text, limit: 3000)
        NSLog("MacTranscribe[App]: refining transcript in \(chunks.count) chunk(s)")
        var refined: [String] = []
        var anySuccess = false
        func processNext(_ index: Int) {
            if index >= chunks.count {
                if anySuccess {
                    let output = refined.joined(separator: " ")
                    if Self.isMeaningfulTranscript(output) {
                        try? output.write(to: url, atomically: true, encoding: .utf8)
                        NSLog("MacTranscribe[App]: refined transcript written chars=\(output.count)")
                    }
                }
                self.endPostRecordingTask()
                return
            }
            LLMRefiner.refine(chunks[index]) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let text):
                        refined.append(text)
                        anySuccess = true
                    case .failure(let error):
                        NSLog("MacTranscribe[App]: refine chunk \(index) failed: \(error.localizedDescription)")
                        refined.append(chunks[index])
                    }
                    processNext(index + 1)
                }
            }
        }
        processNext(0)
    }

    /// Splits text into ~limit-sized chunks on sentence/whitespace boundaries.
    private static func chunkForRefinement(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }
        var chunks: [String] = []
        var current = ""
        // Prefer sentence-ish boundaries; fall back to plain words.
        for piece in text.split(separator: " ", omittingEmptySubsequences: false) {
            if current.count + piece.count + 1 > limit, !current.isEmpty {
                chunks.append(current)
                current = String(piece)
            } else {
                current = current.isEmpty ? String(piece) : current + " " + piece
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// True when the transcript carries actual content — recognizers emit lone
    /// punctuation (".") for silence-only sessions, which isn't worth a file.
    private static func isMeaningfulTranscript(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    /// Persists a finished locked session. The final transcript wins; a useless
    /// final falls back to the last autosave. When nothing meaningful was
    /// recognized: a session with real speech keeps (and reveals) the raw audio
    /// backup so the capture is never lost, while a silence-only session is
    /// discarded entirely — no stray files.
    private func finishLockedSession(with text: String) {
        let stamp = lockSessionStamp ?? Self.fileTimestamp()
        lockSessionStamp = nil
        let autosaveURL = lockAutosaveURL
        lockAutosaveURL = nil
        longForm.audioBackupURL = nil

        var final = text
        if !Self.isMeaningfulTranscript(final), let autosaveURL,
           let autosaved = try? String(contentsOf: autosaveURL, encoding: .utf8) {
            let trimmed = autosaved.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.isMeaningfulTranscript(trimmed) {
                NSLog("MacTranscribe[App]: final transcript empty; recovered \(trimmed.count) chars from autosave")
                final = trimmed
            }
        }

        let dir = Self.transcriptsDirectory
        if Self.isMeaningfulTranscript(final) {
            let url = dir.appendingPathComponent("transcript-\(stamp).txt")
            do {
                // Save the raw transcript immediately — refinement must never
                // be able to lose the capture.
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try final.write(to: url, atomically: true, encoding: .utf8)
                NSLog("MacTranscribe[App]: transcript saved chars=\(final.count)")
                if let autosaveURL { try? FileManager.default.removeItem(at: autosaveURL) }
                NSWorkspace.shared.activateFileViewerSelecting([url])
                // Then refine in place when LLM refinement is configured.
                if settings.llmEnabled && settings.llmConfigured {
                    transcriptWindow.setStatus("Saved — refining with LLM…")
                    refineTranscriptFile(final, at: url)
                } else {
                    transcriptWindow.setStatus("Saved to \(url.lastPathComponent)")
                }
                // Optionally turn the raw transcript into structured meeting
                // notes (independent of the refinement toggle; runs off the
                // raw text so neither task waits on the other). Interpreter
                // sessions save only the conversation — never minutes, even
                // when the option is on.
                let notesReady = settings.meetingNotesProvider == "claude"
                    ? LLMRefiner.isClaudeAvailable()
                    : settings.llmConfigured
                if settings.meetingNotesEnabled && notesReady && lockMode == .meeting {
                    generateMeetingNotes(from: final, stamp: stamp)
                }
            } catch {
                NSLog("MacTranscribe[App]: failed to save transcript: \(error)")
            }
            return
        }

        if let autosaveURL { try? FileManager.default.removeItem(at: autosaveURL) }
        let audioURL = Self.recordingsDirectory.appendingPathComponent("recording-\(stamp).m4a")
        let hadVoice = longForm.sessionPeakLevel >= 0.02
        if hadVoice {
            // Speech happened but transcription produced nothing usable: keep
            // and reveal the audio so the capture is never silently lost.
            if FileManager.default.fileExists(atPath: audioURL.path) {
                NSLog("MacTranscribe[App]: transcript empty despite voice (peak=\(longForm.sessionPeakLevel)); revealing audio backup")
                transcriptWindow.setStatus("No transcript — audio backup kept (\(audioURL.lastPathComponent))")
                NSWorkspace.shared.activateFileViewerSelecting([audioURL])
            }
        } else {
            // Silence-only session: nothing worth keeping.
            NSLog("MacTranscribe[App]: silent locked session discarded (peak=\(longForm.sessionPeakLevel))")
            transcriptWindow.setStatus("No speech detected — nothing saved")
            try? FileManager.default.removeItem(at: audioURL)
        }
    }

    // MARK: - Menu actions

    @objc private func openTranscriptWindow() {
        transcriptWindow.showWindow()
    }

    /// Live Translation keeps a menu-bar shortcut. Enabling it needs the Engine
    /// configured, so send the user to Settings when it isn't.
    @objc private func toggleLiveTranslation() {
        settings.liveTranslationEnabled.toggle()
        if settings.liveTranslationEnabled && !settings.llmConfigured {
            openSettings()
        }
        rebuildMenu()
    }

    @objc private func toggleLockedRecording() {
        if isLockedRecording {
            stopLockedRecording()
        } else {
            startLockedRecording()
        }
    }

    @objc private func openSavedFolder() {
        let dir = Self.baseDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc private func openSettings() {
        settingsController.showWindow()
    }

    @objc private func openPermissions() {
        permissionsController.showWindow()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
