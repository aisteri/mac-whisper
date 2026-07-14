import AVFoundation
import Cocoa
import UniformTypeIdentifiers

/// The app's single settings window, organized into tabs:
///
///  - **General**     — recognition language, trigger keys, silence auto-stop
///  - **Translation** — live translation: languages, audio source, DeepL key,
///                      subtitles, spoken output
///  - **Meeting**     — meeting audio source, automatic meeting notes
///  - **Engine**      — WHO does the work, in two categories: the Meeting
///                      engine (notes + dictation refinement) and the
///                      Translation engine (LLM / DeepL / DeepL Voice)
///
/// Popups and checkboxes persist immediately and fire `onSettingsChanged`;
/// only free-text fields (custom base URL/model, DeepL key) go through their
/// tab's Save button.
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    /// Injected so the General tab can capture new trigger keys.
    var fnMonitor: FnKeyMonitor?
    /// Fired after a trigger-key binding changes, so the app re-applies it.
    var onTriggerChanged: (() -> Void)?
    /// Fired after any setting changes, so the app applies it live and
    /// rebuilds the menu.
    var onSettingsChanged: (() -> Void)?

    // General
    private let recognitionPopup = NSPopUpButton()
    private let shortKeyLabel = NSTextField(labelWithString: "")
    private let shortChangeButton = NSButton()
    private let longKeyLabel = NSTextField(labelWithString: "")
    private let longChangeButton = NSButton()
    private let longClearButton = NSButton()
    private let autoStopCheck = NSButton(checkboxWithTitle: "Auto-stop on sustained silence", target: nil, action: nil)

    // Translation
    private let liveTranslationCheck = NSButton(checkboxWithTitle: "Enable Live Translation for locked recordings", target: nil, action: nil)
    private let sourceLangPopup = NSPopUpButton()
    private let targetLangPopup = NSPopUpButton()
    private let transMicRadio = NSButton(radioButtonWithTitle: "Microphone", target: nil, action: nil)
    private let transSystemRadio = NSButton(radioButtonWithTitle: "System audio (what the Mac plays)", target: nil, action: nil)
    private let subtitleCheck = NSButton(checkboxWithTitle: "Show subtitle overlay at the bottom of the screen", target: nil, action: nil)
    private let speakCheck = NSButton(checkboxWithTitle: "Read translations aloud (TTS)", target: nil, action: nil)
    private let duckCheck = NSButton(checkboxWithTitle: "Duck other audio while speaking", target: nil, action: nil)
    private let voicePopup = NSPopUpButton()
    private let earlySpeakCheck = NSButton(checkboxWithTitle: "Speak ahead of confirmation (lowest delay)", target: nil, action: nil)
    private let transStatusLabel = NSTextField(labelWithString: "")

    // Meeting
    private let micRadio = NSButton(radioButtonWithTitle: "Microphone", target: nil, action: nil)
    private let systemRadio = NSButton(radioButtonWithTitle: "System audio (what the Mac plays)", target: nil, action: nil)
    private let meetingNotesCheck = NSButton(checkboxWithTitle: "Generate meeting notes after a recording", target: nil, action: nil)

    // Engine — Meeting category
    private let providerPopup = NSPopUpButton()
    private let modelPopup = NSPopUpButton()
    private let modelField = NSTextField()
    private let baseURLField = NSTextField()
    private let baseURLLabel = NSTextField(labelWithString: "API Base URL:")
    private var apiKeyLabel: NSTextField!
    private let apiKeyStatusLabel = NSTextField(labelWithString: "")
    private let chatgptAuthButton = NSButton()
    // Engine — Translation category
    private let transProviderPopup = NSPopUpButton()
    private var transModelLabel: NSTextField!
    private let transModelPopup = NSPopUpButton()
    private var deeplKeyLabel: NSTextField!
    private let deeplKeyField = NSTextField()
    private let deeplTestButton = NSButton()
    /// True while the key field shows the masked placeholder rather than the
    /// real key (which lives in Settings; the field is display-only then).
    private var deeplKeyMasked = false
    /// Voices the test confirmation so the whole audio chain is verified.
    private let testSynthesizer = AVSpeechSynthesizer()
    // Engine — shared
    private let glossaryStatusLabel = NSTextField(labelWithString: "")
    private let transGlossaryStatusLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")

    /// Sentinel id for the Claude Code CLI meeting provider (not an LLM API).
    private static let claudeCLIProviderID = "claude-cli"

    /// Trigger-key capture target while the General tab is recording a key.
    private enum CaptureTarget { case none, short, long }
    private var capturing: CaptureTarget = .none

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mac Transcribe Settings"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
        buildUI()
        loadValues()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let tabView = NSTabView(frame: content.bounds)
        tabView.autoresizingMask = [.width, .height]
        tabView.addTabViewItem(makeTab("General", build: buildGeneralTab))
        tabView.addTabViewItem(makeTab("Translation", build: buildTranslationTab))
        tabView.addTabViewItem(makeTab("Meeting", build: buildMeetingTab))
        tabView.addTabViewItem(makeTab("Engine", build: buildEngineTab))
        content.addSubview(tabView)
    }

    private func makeTab(_ title: String, build: (NSView) -> Void) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        let view = NSView()
        build(view)
        item.view = view
        return item
    }

    // MARK: Layout helpers

    private func label(_ title: String, top: CGFloat, in view: NSView, width: CGFloat = 120) -> NSTextField {
        let l = NSTextField(labelWithString: title)
        l.frame = NSRect(x: 20, y: tabHeight - top - 22, width: width, height: 22)
        l.alignment = .right
        view.addSubview(l)
        return l
    }
    private func sectionLabel(_ title: String, top: CGFloat, in view: NSView) {
        let l = NSTextField(labelWithString: title)
        l.font = .boldSystemFont(ofSize: 13)
        l.frame = NSRect(x: 20, y: tabHeight - top - 20, width: 440, height: 20)
        view.addSubview(l)
    }
    private func place(_ v: NSView, x: CGFloat, top: CGFloat, w: CGFloat, h: CGFloat = 26, in view: NSView) {
        v.frame = NSRect(x: x, y: tabHeight - top - h, width: w, height: h)
        view.addSubview(v)
    }
    private func place(_ v: NSView, x: CGFloat, top: CGFloat, w: CGFloat, height: CGFloat, in view: NSView) {
        place(v, x: x, top: top, w: w, h: height, in: view)
    }
    /// Usable height inside a tab (window minus the tab strip/chrome).
    private let tabHeight: CGFloat = 460
    private let fieldX: CGFloat = 150
    private let fieldW: CGFloat = 300

    // MARK: - General tab

    private func buildGeneralTab(_ view: NSView) {
        _ = label("Recognition:", top: 24, in: view)
        recognitionPopup.target = self
        recognitionPopup.action = #selector(recognitionChanged)
        for lang in RecognitionLanguage.allCases {
            recognitionPopup.addItem(withTitle: lang.displayName)
            recognitionPopup.lastItem?.representedObject = lang.rawValue
        }
        place(recognitionPopup, x: fieldX, top: 22, w: fieldW, in: view)
        let recNote = NSTextField(labelWithString: "Language spoken for speech-to-text (dictation and recordings).")
        recNote.font = .systemFont(ofSize: 11); recNote.textColor = .secondaryLabelColor
        place(recNote, x: fieldX, top: 52, w: fieldW, h: 16, in: view)

        _ = label("Dictation key:", top: 92, in: view)
        shortKeyLabel.font = .boldSystemFont(ofSize: 13)
        place(shortKeyLabel, x: fieldX, top: 92, w: 120, h: 22, in: view)
        shortChangeButton.bezelStyle = .rounded
        shortChangeButton.title = "Change…"
        shortChangeButton.target = self
        shortChangeButton.action = #selector(changeShortTapped)
        place(shortChangeButton, x: fieldX + 130, top: 90, w: 130, in: view)

        _ = label("Long-form key:", top: 128, in: view)
        longKeyLabel.font = .boldSystemFont(ofSize: 13)
        place(longKeyLabel, x: fieldX, top: 128, w: 120, h: 22, in: view)
        longChangeButton.bezelStyle = .rounded
        longChangeButton.title = "Change…"
        longChangeButton.target = self
        longChangeButton.action = #selector(changeLongTapped)
        place(longChangeButton, x: fieldX + 130, top: 126, w: 130, in: view)
        longClearButton.bezelStyle = .rounded
        longClearButton.title = "Clear"
        longClearButton.target = self
        longClearButton.action = #selector(clearLongTapped)
        place(longClearButton, x: fieldX + 130, top: 160, w: 130, in: view)

        let keyNote = NSTextField(wrappingLabelWithString:
            "Hold the dictation key to talk; add Shift to toggle a long-form recording. "
            + "To register a combo, hold the modifiers and press the key. The Apple ⌃Fn / ⌃⇧Fn always works too.")
        keyNote.font = .systemFont(ofSize: 11); keyNote.textColor = .secondaryLabelColor
        place(keyNote, x: 20, top: 196, w: 440, h: 48, in: view)

        autoStopCheck.target = self
        autoStopCheck.action = #selector(autoStopChanged)
        place(autoStopCheck, x: 20, top: 256, w: 440, h: 20, in: view)
        let autoStopNote = NSTextField(labelWithString: "Ends a session automatically after a long silence.")
        autoStopNote.font = .systemFont(ofSize: 11); autoStopNote.textColor = .secondaryLabelColor
        place(autoStopNote, x: 40, top: 278, w: 420, h: 16, in: view)
    }

    // MARK: - Translation tab

    private func buildTranslationTab(_ view: NSView) {
        liveTranslationCheck.target = self
        liveTranslationCheck.action = #selector(liveTranslationChanged)
        place(liveTranslationCheck, x: 20, top: 18, w: 440, h: 20, in: view)
        let providerNote = NSTextField(labelWithString: "번역 엔진(LLM / DeepL / DeepL Voice)은 Engine 탭 ▸ Translation에서 선택합니다.")
        providerNote.font = .systemFont(ofSize: 11); providerNote.textColor = .secondaryLabelColor
        place(providerNote, x: 40, top: 40, w: 420, h: 16, in: view)

        _ = label("Source:", top: 70, in: view)
        sourceLangPopup.target = self
        sourceLangPopup.action = #selector(sourceLangChanged)
        place(sourceLangPopup, x: fieldX, top: 68, w: fieldW, in: view)

        _ = label("Target:", top: 106, in: view)
        targetLangPopup.target = self
        targetLangPopup.action = #selector(targetLangChanged)
        place(targetLangPopup, x: fieldX, top: 104, w: fieldW, in: view)

        _ = label("Audio source:", top: 142, in: view)
        transMicRadio.target = self; transMicRadio.action = #selector(transAudioSourceChanged)
        transSystemRadio.target = self; transSystemRadio.action = #selector(transAudioSourceChanged)
        place(transMicRadio, x: fieldX, top: 140, w: fieldW, h: 20, in: view)
        place(transSystemRadio, x: fieldX, top: 164, w: fieldW, h: 20, in: view)

        subtitleCheck.target = self
        subtitleCheck.action = #selector(subtitleChanged)
        place(subtitleCheck, x: 20, top: 204, w: 440, h: 20, in: view)

        speakCheck.target = self
        speakCheck.action = #selector(speakChanged)
        place(speakCheck, x: 20, top: 228, w: 440, h: 20, in: view)
        duckCheck.target = self
        duckCheck.action = #selector(duckChanged)
        place(duckCheck, x: 40, top: 250, w: 420, h: 20, in: view)

        _ = label("Voice:", top: 278, in: view)
        voicePopup.target = self
        voicePopup.action = #selector(voiceChanged)
        place(voicePopup, x: fieldX, top: 276, w: fieldW, in: view)
        let voiceNote = NSTextField(labelWithString:
            "고품질 보이스는 시스템 설정 ▸ 손쉬운 사용 ▸ 콘텐츠 말하기에서 다운로드할 수 있습니다.")
        voiceNote.font = .systemFont(ofSize: 11); voiceNote.textColor = .secondaryLabelColor
        place(voiceNote, x: 40, top: 304, w: 420, h: 16, in: view)

        earlySpeakCheck.target = self
        earlySpeakCheck.action = #selector(earlySpeakChanged)
        place(earlySpeakCheck, x: 40, top: 326, w: 420, h: 20, in: view)
        let earlyNote = NSTextField(labelWithString:
            "확정 전의 안정된 문장을 먼저 읽어 지연을 줄입니다. 드물게 화면 자막과 어긋날 수 있습니다.")
        earlyNote.font = .systemFont(ofSize: 11); earlyNote.textColor = .secondaryLabelColor
        place(earlyNote, x: 60, top: 348, w: 400, h: 16, in: view)

        transStatusLabel.alignment = .left
        transStatusLabel.maximumNumberOfLines = 2
        transStatusLabel.lineBreakMode = .byWordWrapping
        transStatusLabel.textColor = .secondaryLabelColor
        place(transStatusLabel, x: 20, top: 374, w: 440, h: 34, in: view)
    }

    // MARK: - Meeting tab

    private func buildMeetingTab(_ view: NSView) {
        _ = label("Audio source:", top: 24, in: view)
        micRadio.target = self; micRadio.action = #selector(audioSourceChanged)
        systemRadio.target = self; systemRadio.action = #selector(audioSourceChanged)
        place(micRadio, x: fieldX, top: 22, w: fieldW, h: 20, in: view)
        place(systemRadio, x: fieldX, top: 48, w: fieldW, h: 20, in: view)
        let srcNote = NSTextField(labelWithString: "System audio (calls, videos) needs Screen Recording permission.")
        srcNote.font = .systemFont(ofSize: 11); srcNote.textColor = .secondaryLabelColor
        place(srcNote, x: fieldX, top: 74, w: fieldW, h: 16, in: view)

        meetingNotesCheck.target = self
        meetingNotesCheck.action = #selector(meetingNotesChanged)
        place(meetingNotesCheck, x: 20, top: 120, w: 440, h: 20, in: view)
        let notesNote = NSTextField(wrappingLabelWithString:
            "After a recording ends, structured minutes (attendees, discussion, decisions, "
            + "action items) are generated as Markdown by the Meeting engine (Engine tab). "
            + "Off during Live Translation.")
        notesNote.font = .systemFont(ofSize: 11); notesNote.textColor = .secondaryLabelColor
        place(notesNote, x: 40, top: 142, w: 420, h: 44, in: view)
    }

    // MARK: - Engine tab

    private func buildEngineTab(_ view: NSView) {
        let desc = NSTextField(labelWithString:
            "Meeting: 회의록·받아쓰기 보정  /  Translation: 실시간 번역")
        desc.font = .systemFont(ofSize: 11); desc.textColor = .secondaryLabelColor
        place(desc, x: 20, top: 8, w: 440, h: 16, in: view)

        func style(_ field: NSTextField, top: CGFloat) {
            place(field, x: fieldX, top: top, w: fieldW, in: view)
            field.isEditable = true; field.isSelectable = true
            field.isBezeled = true; field.bezelStyle = .roundedBezel
        }

        // Meeting category — the LLM behind notes + dictation refinement.
        sectionLabel("Meeting", top: 32, in: view)
        _ = label("Provider:", top: 60, in: view)
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        for provider in LLMProvider.all {
            providerPopup.addItem(withTitle: provider.displayName)
            providerPopup.lastItem?.representedObject = provider.id
        }
        providerPopup.menu?.addItem(.separator())
        providerPopup.addItem(withTitle: "Claude Code (CLI)")
        providerPopup.lastItem?.representedObject = Self.claudeCLIProviderID
        place(providerPopup, x: fieldX, top: 58, w: fieldW, in: view)

        _ = label("Model:", top: 96, in: view)
        place(modelPopup, x: fieldX, top: 94, w: fieldW, in: view)
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged)
        style(modelField, top: 96)
        modelField.placeholderString = "gpt-4o-mini"

        baseURLLabel.stringValue = "API Base URL:"
        baseURLLabel.alignment = .right
        place(baseURLLabel, x: 20, top: 132, w: 120, h: 22, in: view)
        style(baseURLField, top: 132)
        baseURLField.placeholderString = "https://api.openai.com/v1"

        apiKeyLabel = label("Account:", top: 168, in: view)
        apiKeyStatusLabel.font = .systemFont(ofSize: 11)
        apiKeyStatusLabel.textColor = .secondaryLabelColor
        place(apiKeyStatusLabel, x: fieldX, top: 168, w: fieldW, h: 22, in: view)
        chatgptAuthButton.title = "Sign in with ChatGPT"
        chatgptAuthButton.bezelStyle = .rounded
        chatgptAuthButton.target = self
        chatgptAuthButton.action = #selector(chatgptAuthTapped)
        place(chatgptAuthButton, x: fieldX, top: 194, w: 200, h: 28, in: view)

        // Meeting glossary lives INSIDE the Meeting section: STT corrections
        // + domain terms for notes.
        _ = label("Glossary:", top: 230, in: view)
        glossaryStatusLabel.font = .systemFont(ofSize: 11)
        glossaryStatusLabel.textColor = .secondaryLabelColor
        glossaryStatusLabel.lineBreakMode = .byTruncatingMiddle
        place(glossaryStatusLabel, x: fieldX, top: 230, w: 140, h: 22, in: view)
        let chooseButton = NSButton(title: "Attach…", target: self, action: #selector(chooseGlossaryTapped))
        chooseButton.bezelStyle = .rounded
        place(chooseButton, x: fieldX + 146, top: 226, w: 82, height: 28, in: view)
        let editButton = NSButton(title: "Edit", target: self, action: #selector(editGlossaryTapped))
        editButton.bezelStyle = .rounded
        place(editButton, x: fieldX + 232, top: 226, w: 68, height: 28, in: view)

        // Translation category — which engine translates live sessions.
        sectionLabel("Translation", top: 266, in: view)
        _ = label("Provider:", top: 294, in: view)
        transProviderPopup.target = self
        transProviderPopup.action = #selector(transProviderChanged)
        for (id, title) in [("apple", "Apple Translation (on-device, free)"),
                            ("llm", "LLM (uses the Meeting account)"),
                            ("deepl-voice", "DeepL Voice (streaming)")] {
            transProviderPopup.addItem(withTitle: title)
            transProviderPopup.lastItem?.representedObject = id
        }
        place(transProviderPopup, x: fieldX, top: 292, w: fieldW, in: view)

        transModelLabel = label("Model:", top: 330, in: view)
        transModelPopup.target = self
        transModelPopup.action = #selector(transModelChanged)
        place(transModelPopup, x: fieldX, top: 328, w: fieldW, in: view)

        // The DeepL key shares the model row — exactly one of them shows,
        // depending on the translation provider.
        deeplKeyLabel = label("DeepL API Key:", top: 330, in: view)
        place(deeplKeyField, x: fieldX, top: 328, w: fieldW - 86, in: view)
        deeplKeyField.isEditable = true; deeplKeyField.isBezeled = true
        deeplKeyField.bezelStyle = .roundedBezel
        deeplKeyField.placeholderString = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
        deeplKeyField.delegate = self
        deeplTestButton.title = "Test"
        deeplTestButton.bezelStyle = .rounded
        deeplTestButton.target = self
        deeplTestButton.action = #selector(deeplTestTapped)
        place(deeplTestButton, x: fieldX + fieldW - 80, top: 327, w: 80, height: 28, in: view)

        // Translation glossary: source-term -> target-term pairs, a separate
        // file — mixing it with the STT-correction glossary made every "->"
        // line ambiguous. Feeds DeepL Voice sessions and the LLM quality pass.
        _ = label("Trans. Glossary:", top: 366, in: view)
        transGlossaryStatusLabel.font = .systemFont(ofSize: 11)
        transGlossaryStatusLabel.textColor = .secondaryLabelColor
        transGlossaryStatusLabel.lineBreakMode = .byTruncatingMiddle
        place(transGlossaryStatusLabel, x: fieldX, top: 366, w: 140, h: 22, in: view)
        let transChooseButton = NSButton(title: "Attach…", target: self, action: #selector(chooseTransGlossaryTapped))
        transChooseButton.bezelStyle = .rounded
        place(transChooseButton, x: fieldX + 146, top: 362, w: 82, height: 28, in: view)
        let transEditButton = NSButton(title: "Edit", target: self, action: #selector(editTransGlossaryTapped))
        transEditButton.bezelStyle = .rounded
        place(transEditButton, x: fieldX + 232, top: 362, w: 68, height: 28, in: view)

        statusLabel.alignment = .left
        statusLabel.maximumNumberOfLines = 2
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.textColor = .secondaryLabelColor
        place(statusLabel, x: 20, top: 404, w: 300, h: 34, in: view)

        let testButton = NSButton(title: "Test", target: self, action: #selector(testTapped))
        testButton.bezelStyle = .rounded
        place(testButton, x: 260, top: 424, w: 90, h: 30, in: view)
        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        place(saveButton, x: 360, top: 424, w: 100, h: 30, in: view)
    }

    // MARK: - Load

    private func loadValues() {
        let s = Settings.shared
        selectByRepresented(recognitionPopup, s.language.rawValue)
        refreshTriggerKeys()
        autoStopCheck.state = s.silenceAutoStopEnabled ? .on : .off

        liveTranslationCheck.state = s.liveTranslationEnabled ? .on : .off
        transMicRadio.state = s.translationAudioSourceIsSystem ? .off : .on
        transSystemRadio.state = s.translationAudioSourceIsSystem ? .on : .off
        // A previously saved key is treated as verified: show the mask.
        deeplKeyField.stringValue = s.deeplAPIKey.isEmpty ? "" : Self.keyMask
        deeplKeyMasked = !s.deeplAPIKey.isEmpty
        subtitleCheck.state = s.subtitleOverlayEnabled ? .on : .off
        speakCheck.state = s.speakTranslations ? .on : .off
        duckCheck.state = s.duckWhileSpeaking ? .on : .off
        earlySpeakCheck.state = s.earlySpeechEnabled ? .on : .off
        // Voice popup filled by rebuildTranslationLanguages() below.

        micRadio.state = s.lockedAudioSourceIsSystem ? .off : .on
        systemRadio.state = s.lockedAudioSourceIsSystem ? .on : .off
        meetingNotesCheck.state = s.meetingNotesEnabled ? .on : .off

        // Engine ▸ Meeting: the Claude CLI choice lives in
        // meetingNotesProvider; every LLM choice lives in llmProvider.
        if s.meetingNotesProvider == "claude" {
            selectByRepresented(providerPopup, Self.claudeCLIProviderID)
        } else {
            selectByRepresented(providerPopup, s.llmProvider.id)
        }
        baseURLField.stringValue = s.llmProvider.isCustom ? s.llmBaseURL : s.llmProvider.baseURL
        modelField.stringValue = s.llmProvider.isCustom ? s.llmModel : ""
        rebuildModelPopup(selecting: s.llmModel)

        // Engine ▸ Translation.
        selectByRepresented(transProviderPopup, s.translationProvider)
        rebuildTransModelPopup(selecting: s.translationLLMModel)

        applyProviderVisibility()
        applyTranslationVisibility()
        rebuildTranslationLanguages()
        refreshAPIKeyStatus()
        refreshGlossaryStatus()
    }

    private func selectByRepresented(_ popup: NSPopUpButton, _ value: String) {
        for item in popup.itemArray where (item.representedObject as? String) == value {
            popup.select(item)
            return
        }
        if popup.numberOfItems > 0 { popup.selectItem(at: 0) }
    }

    private func represented(_ popup: NSPopUpButton) -> String {
        popup.selectedItem?.representedObject as? String ?? ""
    }

    // MARK: - General actions

    @objc private func recognitionChanged() {
        if let lang = RecognitionLanguage(rawValue: represented(recognitionPopup)) {
            Settings.shared.language = lang
        }
        onSettingsChanged?()
    }
    @objc private func autoStopChanged() {
        Settings.shared.silenceAutoStopEnabled = autoStopCheck.state == .on
        onSettingsChanged?()
    }

    private func refreshTriggerKeys() {
        let s = Settings.shared
        shortKeyLabel.stringValue = FnKeyMonitor.chordName(s.triggerKey)
        if let long = s.longTriggerKey {
            longKeyLabel.stringValue = FnKeyMonitor.chordName(long)
            longClearButton.isEnabled = capturing == .none
        } else {
            longKeyLabel.stringValue = "Trigger + Shift"
            longClearButton.isEnabled = false
        }
        shortChangeButton.title = capturing == .short ? "Press key/combo…" : "Change…"
        longChangeButton.title = capturing == .long ? "Press key/combo…" : "Change…"
        shortChangeButton.isEnabled = capturing == .none
        longChangeButton.isEnabled = capturing == .none
    }

    private func beginCapture(_ target: CaptureTarget) {
        guard let fnMonitor, capturing == .none else { return }
        capturing = target
        refreshTriggerKeys()
        fnMonitor.captureNextKey = { [weak self] chord in
            guard let self else { return }
            switch self.capturing {
            case .short: Settings.shared.triggerKey = chord
            case .long: Settings.shared.longTriggerKey = chord
            case .none: break
            }
            self.capturing = .none
            self.onTriggerChanged?()
            self.refreshTriggerKeys()
        }
    }
    @objc private func changeShortTapped() { beginCapture(.short) }
    @objc private func changeLongTapped() { beginCapture(.long) }
    @objc private func clearLongTapped() {
        Settings.shared.longTriggerKey = nil
        onTriggerChanged?()
        refreshTriggerKeys()
    }

    // MARK: - Translation actions

    @objc private func liveTranslationChanged() {
        Settings.shared.liveTranslationEnabled = liveTranslationCheck.state == .on
        onSettingsChanged?()
    }

    /// Speech-to-text must listen in the language being SPOKEN — a Korean
    /// recognizer turns Japanese speech into garbage before the translator
    /// ever sees it. Pinning a source drags the recognition language along.
    private static let sourceToRecognition: [String: RecognitionLanguage] = [
        // DeepL codes
        "EN": .english, "KO": .korean, "JA": .japanese, "ZH": .simplifiedChinese,
        // LLM prompt names
        "English": .english, "Korean": .korean, "Japanese": .japanese,
        "Simplified Chinese": .simplifiedChinese, "Traditional Chinese": .traditionalChinese,
    ]

    @objc private func sourceLangChanged() {
        let s = Settings.shared
        let value = represented(sourceLangPopup)
        if s.deeplEnabled { s.deeplSourceLang = value } else { s.interpreterSourceLanguage = value }
        if let recognition = Self.sourceToRecognition[value], s.language != recognition {
            s.language = recognition
            selectByRepresented(recognitionPopup, recognition.rawValue)
            transStatusLabel.textColor = .secondaryLabelColor
            transStatusLabel.stringValue = "Recognition language → \(recognition.displayName) (전사는 발화 언어로 들어야 합니다)"
        } else if !value.isEmpty, value != TranslationLanguage.autoSource,
                  Self.sourceToRecognition[value] == nil {
            transStatusLabel.textColor = .systemOrange
            transStatusLabel.stringValue = "Speech recognition does not support this source language."
        }
        onSettingsChanged?()
    }

    @objc private func targetLangChanged() {
        let s = Settings.shared
        let value = represented(targetLangPopup)
        if s.deeplEnabled { s.deeplTargetLang = value } else { s.interpreterTargetLanguage = value }
        rebuildVoicePopup()
        onSettingsChanged?()
    }

    @objc private func transAudioSourceChanged() {
        Settings.shared.translationAudioSourceIsSystem = transSystemRadio.state == .on
        onSettingsChanged?()
    }

    @objc private func subtitleChanged() {
        Settings.shared.subtitleOverlayEnabled = subtitleCheck.state == .on
        onSettingsChanged?()
    }
    @objc private func speakChanged() {
        Settings.shared.speakTranslations = speakCheck.state == .on
        onSettingsChanged?()
    }
    @objc private func duckChanged() {
        Settings.shared.duckWhileSpeaking = duckCheck.state == .on
        onSettingsChanged?()
    }
    @objc private func earlySpeakChanged() {
        Settings.shared.earlySpeechEnabled = earlySpeakCheck.state == .on
        onSettingsChanged?()
    }

    /// The spoken-output voice tag for the active provider's target language.
    private func currentVoiceTag() -> String {
        let s = Settings.shared
        return SpeechOutput.languageTag(
            deepl: s.deeplEnabled ? s.deeplTargetLang : "",
            llm: s.interpreterTargetLanguage)
    }

    /// Fills the voice popup with the target language's installed voices,
    /// best quality first; "Automatic" (the default) picks the highest
    /// quality at session start.
    private func rebuildVoicePopup() {
        let s = Settings.shared
        let tag = currentVoiceTag()
        voicePopup.removeAllItems()
        voicePopup.addItem(withTitle: "Automatic (best installed)")
        voicePopup.lastItem?.representedObject = ""
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.prefix(2) == tag.prefix(2) }
            .sorted {
                if $0.quality != $1.quality { return $0.quality.rawValue > $1.quality.rawValue }
                return $0.name < $1.name
            }
        for voice in voices {
            // Recent macOS already bakes the quality into the name
            // ("Jian (Premium)") — only label voices that don't carry it.
            let quality = voice.quality == .premium ? "Premium"
                : voice.quality == .enhanced ? "Enhanced" : ""
            let title = quality.isEmpty || voice.name.contains(quality)
                ? voice.name : "\(voice.name) (\(quality))"
            voicePopup.addItem(withTitle: title)
            voicePopup.lastItem?.representedObject = voice.identifier
        }
        selectByRepresented(voicePopup, s.speechVoiceIdentifier)
    }

    /// Persists the choice and speaks a short preview so it is judged by ear.
    @objc private func voiceChanged() {
        let s = Settings.shared
        s.speechVoiceIdentifier = represented(voicePopup)
        onSettingsChanged?()
        let tag = currentVoiceTag()
        let phrase = tag.hasPrefix("ko") ? "통역 음성은 이렇게 들립니다."
            : tag.hasPrefix("ja") ? "通訳の音声はこのように聞こえます。"
            : "The interpreter voice sounds like this."
        let utterance = AVSpeechUtterance(string: phrase)
        let id = s.speechVoiceIdentifier
        utterance.voice = id.isEmpty
            ? (SpeechOutput.bestVoice(forLanguage: tag) ?? AVSpeechSynthesisVoice(language: tag))
            : AVSpeechSynthesisVoice(identifier: id)
        testSynthesizer.stopSpeaking(at: .immediate)
        testSynthesizer.speak(utterance)
    }

    // MARK: - DeepL key (plain until verified, fully masked after)

    /// The key stays plain (and freely pastable/editable) until the Test
    /// button VERIFIES it against the Voice endpoint — only then does the
    /// field mask completely. Clicking into a masked field brings the real
    /// key back for editing. NSSecureTextField is not used (it blocks paste).
    private static let keyMask = String(repeating: "•", count: 20)

    func controlTextDidBeginEditing(_ notification: Notification) {
        guard (notification.object as? NSTextField) === deeplKeyField, deeplKeyMasked else { return }
        deeplKeyMasked = false
        deeplKeyField.stringValue = Settings.shared.deeplAPIKey
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard (notification.object as? NSTextField) === deeplKeyField, !deeplKeyMasked else { return }
        // Persist on blur, but keep the text visible — masking waits for a
        // successful Test so the user can see what they typed until then.
        Settings.shared.deeplAPIKey = deeplKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        onSettingsChanged?()
    }

    /// Tests the key against the VOICE endpoint (a session grant verifies the
    /// key, the paid plan, and Voice access in one round-trip), then speaks a
    /// confirmation so the whole audio chain is verified by ear — and masks
    /// the now-proven key.
    @objc private func deeplTestTapped() {
        // Pick up whatever is in the field, saved or not.
        if !deeplKeyMasked {
            Settings.shared.deeplAPIKey = deeplKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let key = Settings.shared.deeplAPIKey
        guard !key.isEmpty else {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = "Enter the DeepL API key first."
            return
        }
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Testing Voice API…"
        DeepLVoiceSession.testConnection(apiKey: key) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.statusLabel.textColor = .systemGreen
                    self.statusLabel.stringValue = "✓ Voice session granted"
                    // Key proven — hide it completely now.
                    self.deeplKeyField.stringValue = Self.keyMask
                    self.deeplKeyMasked = true
                    self.window?.makeFirstResponder(nil)
                    let tag = SpeechOutput.languageTag(deepl: Settings.shared.deeplTargetLang, llm: "")
                    let phrase = tag.hasPrefix("ko") ? "딥엘 보이스 연결이 확인되었습니다."
                        : tag.hasPrefix("ja") ? "DeepL Voiceの接続が確認できました。"
                        : "DeepL Voice connection verified."
                    let utterance = AVSpeechUtterance(string: phrase)
                    utterance.voice = AVSpeechSynthesisVoice(language: tag)
                    self.testSynthesizer.speak(utterance)
                case .failure(let error):
                    self.statusLabel.textColor = .systemRed
                    self.statusLabel.stringValue = "Failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Fills the language popups for the active translation provider —
    /// DeepL codes or LLM prompt names, bound to their respective settings.
    private func rebuildTranslationLanguages() {
        let s = Settings.shared
        sourceLangPopup.removeAllItems()
        targetLangPopup.removeAllItems()
        if s.deeplEnabled {
            for lang in DeepLTranslator.sourceLanguages {
                sourceLangPopup.addItem(withTitle: lang.display)
                sourceLangPopup.lastItem?.representedObject = lang.code
            }
            for lang in DeepLTranslator.targetLanguages {
                targetLangPopup.addItem(withTitle: lang.display)
                targetLangPopup.lastItem?.representedObject = lang.code
            }
            selectByRepresented(sourceLangPopup, s.deeplSourceLang)
            selectByRepresented(targetLangPopup, s.deeplTargetLang)
        } else {
            for lang in TranslationLanguage.sources {
                sourceLangPopup.addItem(withTitle: lang.display)
                sourceLangPopup.lastItem?.representedObject = lang.prompt
            }
            for lang in TranslationLanguage.targets {
                targetLangPopup.addItem(withTitle: lang.display)
                targetLangPopup.lastItem?.representedObject = lang.prompt
            }
            selectByRepresented(sourceLangPopup, s.interpreterSourceLanguage)
            selectByRepresented(targetLangPopup, s.interpreterTargetLanguage)
        }
        // The voice list follows the target language.
        rebuildVoicePopup()
    }

    // MARK: - Meeting actions

    @objc private func audioSourceChanged() {
        Settings.shared.lockedAudioSourceIsSystem = systemRadio.state == .on
        onSettingsChanged?()
    }
    @objc private func meetingNotesChanged() {
        Settings.shared.meetingNotesEnabled = meetingNotesCheck.state == .on
        onSettingsChanged?()
    }

    // MARK: - Glossary

    private func refreshGlossaryStatus() {
        let s = Settings.shared
        let count = s.glossaryTerms.count
        if count > 0 {
            glossaryStatusLabel.stringValue = "✓ \(count) terms — \(s.glossaryURL.lastPathComponent)"
            glossaryStatusLabel.textColor = .systemGreen
        } else {
            glossaryStatusLabel.stringValue = "None (optional)"
            glossaryStatusLabel.textColor = .secondaryLabelColor
        }
        let pairCount = s.translationGlossaryCount
        if pairCount > 0 {
            transGlossaryStatusLabel.stringValue = "✓ \(pairCount) terms — \(s.translationGlossaryURL.lastPathComponent)"
            transGlossaryStatusLabel.textColor = .systemGreen
        } else {
            transGlossaryStatusLabel.stringValue = "None (optional)"
            transGlossaryStatusLabel.textColor = .secondaryLabelColor
        }
    }

    @objc private func chooseTransGlossaryTapped() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .json]
        panel.message = "번역 용어집 선택 — JSON 용어 시트({term, ko, jp, en}) 또는 \"원어 -> 번역어\" 텍스트"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Settings.shared.translationGlossaryURL = url
            self?.refreshGlossaryStatus()
        }
    }

    @objc private func editTransGlossaryTapped() {
        let url = Settings.shared.translationGlossaryURL
        if !FileManager.default.fileExists(atPath: url.path) {
            let template = """
            # Mac Transcribe 번역 용어집 — 한 줄에 하나씩 "원어 -> 번역어".
            # 이 용어가 원문에 나오면 지정한 번역으로 옮깁니다.
            # 예시:
            # 投放 -> 캠페인 집행
            # Findlab -> 파인드랩
            """
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? template.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func chooseGlossaryTapped() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText]
        panel.message = "Choose a glossary text file (one term per line; \"wrong -> right\" maps a mis-transcription)"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Settings.shared.glossaryURL = url
            self?.refreshGlossaryStatus()
        }
    }

    @objc private func editGlossaryTapped() {
        let url = Settings.shared.glossaryURL
        if !FileManager.default.fileExists(atPath: url.path) {
            let template = """
            # Mac Transcribe glossary — one term per line.
            # Lines starting with # are comments.
            # Map a frequent mis-transcription with:  wrong -> right
            # Examples:
            # Vigloo
            # 스푼라디오
            # jooq -> jOOQ
            """
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? template.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Engine ▸ Meeting actions

    private var selectedMeetingProviderID: String { represented(providerPopup) }
    private var selectedProvider: LLMProvider {
        LLMProvider.provider(id: selectedMeetingProviderID.isEmpty ? "custom" : selectedMeetingProviderID)
    }
    private var isClaudeCLISelected: Bool { selectedMeetingProviderID == Self.claudeCLIProviderID }

    @objc private func providerChanged() {
        let s = Settings.shared
        if isClaudeCLISelected {
            s.meetingNotesProvider = "claude"
        } else {
            s.meetingNotesProvider = "engine"
            s.llmProviderID = selectedMeetingProviderID
            let provider = selectedProvider
            if provider.isCustom {
                if baseURLField.stringValue.isEmpty { baseURLField.stringValue = s.llmBaseURL }
                if modelField.stringValue.isEmpty { modelField.stringValue = s.llmModel }
            } else {
                baseURLField.stringValue = provider.baseURL
                rebuildModelPopup(selecting: provider.defaultModel)
                s.llmModel = modelPopup.titleOfSelectedItem ?? provider.defaultModel
            }
        }
        applyProviderVisibility()
        refreshAPIKeyStatus()
        statusLabel.stringValue = ""
        onSettingsChanged?()
    }

    @objc private func modelChanged() {
        guard !isClaudeCLISelected, !selectedProvider.isCustom else { return }
        Settings.shared.llmModel = modelPopup.titleOfSelectedItem ?? ""
        onSettingsChanged?()
    }

    private func refreshAPIKeyStatus() {
        if isClaudeCLISelected {
            apiKeyLabel.stringValue = "Account:"
            if LLMRefiner.isClaudeAvailable() {
                apiKeyStatusLabel.stringValue = "✓ claude CLI installed (sign in via `claude` in Terminal)"
                apiKeyStatusLabel.textColor = .systemGreen
            } else {
                apiKeyStatusLabel.stringValue = "✗ claude CLI not found — install Claude Code first"
                apiKeyStatusLabel.textColor = .systemRed
            }
            return
        }
        if selectedProvider.proto == .chatgpt {
            apiKeyLabel.stringValue = "Account:"
            if ChatGPTOAuth.shared.isSignedIn {
                apiKeyStatusLabel.stringValue = "✓ Signed in with ChatGPT"
                apiKeyStatusLabel.textColor = .systemGreen
                chatgptAuthButton.title = "Sign out"
            } else {
                apiKeyStatusLabel.stringValue = "✗ Not signed in"
                apiKeyStatusLabel.textColor = .systemRed
                chatgptAuthButton.title = "Sign in with ChatGPT"
            }
            return
        }
        apiKeyLabel.stringValue = "API Key:"
        let name = Settings.apiKeyEnvName
        if Settings.shared.llmAPIKeyIsSet {
            apiKeyStatusLabel.stringValue = "✓ Set via $\(name)"
            apiKeyStatusLabel.textColor = .systemGreen
        } else {
            apiKeyStatusLabel.stringValue = "✗ Not set ($\(name) or ~/.config/macwhisper/.env)"
            apiKeyStatusLabel.textColor = .systemRed
        }
    }

    @objc private func chatgptAuthTapped() {
        if ChatGPTOAuth.shared.isSignedIn {
            ChatGPTOAuth.shared.signOut()
            refreshAPIKeyStatus()
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = "Signed out."
            return
        }
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Complete the sign-in in your browser…"
        ChatGPTOAuth.shared.signIn { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshAPIKeyStatus()
                switch result {
                case .success:
                    self.statusLabel.textColor = .systemGreen
                    self.statusLabel.stringValue = "Signed in ✓"
                case .failure(let error):
                    self.statusLabel.textColor = .systemRed
                    self.statusLabel.stringValue = "Sign-in failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func rebuildModelPopup(selecting model: String) {
        modelPopup.removeAllItems()
        let provider = selectedProvider
        modelPopup.addItems(withTitles: provider.models)
        if provider.models.contains(model) {
            modelPopup.selectItem(withTitle: model)
        } else if let first = provider.models.first {
            modelPopup.selectItem(withTitle: first)
        }
    }

    private func applyProviderVisibility() {
        let claude = isClaudeCLISelected
        let custom = !claude && selectedProvider.isCustom
        modelPopup.isHidden = claude || custom
        modelField.isHidden = claude || !custom
        baseURLLabel.isHidden = claude
        baseURLField.isHidden = claude
        baseURLField.isEditable = custom
        baseURLField.isSelectable = custom
        baseURLField.textColor = custom ? .labelColor : .secondaryLabelColor
        chatgptAuthButton.isHidden = claude || selectedProvider.proto != .chatgpt
    }

    // MARK: - Engine ▸ Translation actions

    @objc private func transProviderChanged() {
        Settings.shared.translationProvider = represented(transProviderPopup)
        applyTranslationVisibility()
        rebuildTranslationLanguages()
        onSettingsChanged?()
    }

    @objc private func transModelChanged() {
        Settings.shared.translationLLMModel = transModelPopup.titleOfSelectedItem ?? ""
        onSettingsChanged?()
    }

    private func rebuildTransModelPopup(selecting model: String) {
        transModelPopup.removeAllItems()
        transModelPopup.addItems(withTitles: selectedProvider.models)
        if selectedProvider.models.contains(model) {
            transModelPopup.selectItem(withTitle: model)
        } else if let first = selectedProvider.models.first {
            transModelPopup.selectItem(withTitle: first)
        }
    }

    private func applyTranslationVisibility() {
        let provider = Settings.shared.translationProvider
        // Apple needs nothing configured; LLM shows a model; DeepL shows a key.
        transModelLabel.isHidden = provider != "llm"
        transModelPopup.isHidden = provider != "llm"
        deeplKeyLabel.isHidden = provider != "deepl-voice"
        deeplKeyField.isHidden = provider != "deepl-voice"
        deeplTestButton.isHidden = provider != "deepl-voice"
    }

    // MARK: - Engine shared actions

    private func currentConfig() -> (provider: LLMProvider, baseURL: String, model: String, key: String) {
        let provider = selectedProvider
        let key = Settings.shared.llmAPIKey
        if provider.isCustom {
            let base = baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return (provider, base, model, key)
        }
        let model = modelPopup.titleOfSelectedItem ?? provider.defaultModel
        return (provider, provider.baseURL, model, key)
    }

    @objc private func saveTapped() {
        guard !isClaudeCLISelected else {
            statusLabel.textColor = .systemGreen
            statusLabel.stringValue = "Saved."
            return
        }
        let cfg = currentConfig()
        let s = Settings.shared
        s.llmProviderID = cfg.provider.id
        if cfg.provider.isCustom { s.llmBaseURL = cfg.baseURL }
        s.llmModel = cfg.model
        refreshAPIKeyStatus()
        statusLabel.textColor = .systemGreen
        statusLabel.stringValue = "Saved."
        onSettingsChanged?()
    }

    @objc private func testTapped() {
        guard !isClaudeCLISelected else {
            statusLabel.textColor = LLMRefiner.isClaudeAvailable() ? .systemGreen : .systemRed
            statusLabel.stringValue = LLMRefiner.isClaudeAvailable()
                ? "✓ claude CLI found" : "✗ claude CLI not found"
            return
        }
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Testing…"
        let cfg = currentConfig()
        LLMRefiner.request(text: "Hello", baseURL: cfg.baseURL, apiKey: cfg.key, model: cfg.model, proto: cfg.provider.proto) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let output):
                    self.statusLabel.textColor = .systemGreen
                    self.statusLabel.stringValue = "Success ✓  Response: \(output)"
                case .failure(let error):
                    self.statusLabel.textColor = .systemRed
                    self.statusLabel.stringValue = "Failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Window

    func windowWillClose(_ notification: Notification) {
        fnMonitor?.captureNextKey = nil
        capturing = .none
    }

    func showWindow() {
        loadValues()
        statusLabel.stringValue = ""
        transStatusLabel.stringValue = ""
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
