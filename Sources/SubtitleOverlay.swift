import Cocoa

/// Video-caption-style overlay for locked (long-form) recordings: white text on
/// a dim black backdrop, pinned to the very bottom of the screen — lower than
/// the push-to-talk HUD — so it reads like movie subtitles and stays out of the
/// way. Shows the raw recognizer text (pre-LLM) as it arrives. A close button
/// appears on mouse-over; closing hides the captions without touching the
/// recording.
final class SubtitleOverlay {
    /// Fired when the user closes the overlay (recording continues).
    var onCloseRequested: (() -> Void)?

    private let panel: NSPanel
    /// Transparent root hosting the caption box; oversized so the close button
    /// can overhang the box's top-right corner without being clipped.
    private let container: HoverView
    /// The visible black caption box.
    private let captionBox = NSView()
    private let textField: NSTextField
    private let closeButton: NSButton

    private let font = NSFont.systemFont(ofSize: 17, weight: .medium)
    private let hPadding: CGFloat = 18
    private let vPadding: CGFloat = 10
    private let bottomMargin: CGFloat = 14
    private let cornerRadius: CGFloat = 8
    /// How many trailing sentences to show.
    var maxLines = 2 {
        didSet { textField.maximumNumberOfLines = renderedLineCap }
    }
    /// Broadcast-caption idle fade. On for meeting captions (a stale line
    /// reads as still-being-said); OFF for live translation, where a line
    /// must stay put until the next utterance scrolls it — or its own
    /// delayed translation arrives — rather than vanishing mid-read.
    var fadeWhenIdle = true
    /// Hard cap on RENDERED lines — each caption line can wrap, so this must
    /// exceed maxLines or the newest text gets clipped. Two rendered lines
    /// per caption line covers a long sentence that wraps once.
    private var renderedLineCap: Int { max(4, maxLines * 2) }
    /// Roughly the last caption-worth of text to show.
    private var tailLength: Int { maxLines * 70 }
    private let closeSize: CGFloat = 20
    /// Extra room above/right of the caption box for the overhanging button.
    private var overhang: CGFloat { closeSize / 2 }

    /// Armed by show(); the panel becomes visible only once real speech text
    /// arrives, so a silent stretch never shows an empty black box.
    private var armed = false
    /// Generation token for flashStatus auto-hide.
    private var flashGen = 0

    /// Broadcast-caption behavior: when the caption content stops changing
    /// (speech paused), fade the box out after a beat instead of leaving a
    /// stale line on screen that reads as if it were still being said. New
    /// content brings it right back.
    private var lastContent = ""
    private var lastHighlight = 0
    private var lastContentAt = Date.distantPast
    private var idleTimer: Timer?
    /// 12 s, not shorter: interpreter captions update only when the voice
    /// speaks, and translated sentences legitimately arrive ten-plus
    /// seconds apart — a 4 s fade kept vanishing captions mid-meeting.
    private let idleFadeAfter: TimeInterval = 12.0

    init() {
        let rect = NSRect(x: 0, y: 0, width: 400, height: 44)
        panel = NSPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        container = HoverView(frame: rect)
        // Layer-backed all the way down: without this, resizing the panel as
        // captions grow (one line -> two) left the previous frame's pixels
        // behind, so old and new box/text rendered on top of each other.
        container.wantsLayer = true
        panel.contentView = container

        captionBox.wantsLayer = true
        captionBox.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        captionBox.layer?.cornerRadius = cornerRadius
        container.addSubview(captionBox)

        textField = NSTextField(wrappingLabelWithString: "")
        textField.font = font
        textField.textColor = .white
        textField.backgroundColor = .clear
        textField.drawsBackground = false
        textField.isBezeled = false
        textField.isEditable = false
        textField.isSelectable = false
        textField.alignment = .center
        // Concrete initial cap; maxLines.didSet keeps it in sync afterward.
        textField.maximumNumberOfLines = max(4, maxLines * 2)
        textField.lineBreakMode = .byTruncatingHead
        captionBox.addSubview(textField)

        closeButton = NSButton()
        closeButton.bezelStyle = .circular
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close subtitles")
        closeButton.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        closeButton.isHidden = true
        container.addSubview(closeButton)
        closeButton.target = self
        closeButton.action = #selector(closeTapped)

        container.onHover = { [weak self] hovering in
            self?.closeButton.isHidden = !hovering
        }
    }

    @objc private func closeTapped() {
        hide()
        onCloseRequested?()
    }

    // MARK: - Presentation

    var isVisible: Bool { panel.isVisible }

    /// Arms the overlay for the session. Nothing is shown yet — the panel
    /// appears with the first real speech text (see update).
    func show() {
        armed = true
        textField.stringValue = ""
        lastContent = ""
        lastContentAt = .distantPast
        startIdleTimer()
    }

    func hide() {
        armed = false
        idleTimer?.invalidate()
        idleTimer = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
        })
    }

    /// When set, the overlay never idle-fades while this returns true —
    /// the caption content only updates as each sentence STARTS playing,
    /// so during a long utterance the content clock goes stale while the
    /// voice is still audibly mid-sentence.
    var isBusy: (() -> Bool)?

    private func startIdleTimer() {
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.fadeWhenIdle, self.armed, self.panel.isVisible,
                  self.lastContentAt != .distantPast,
                  !(self.isBusy?() ?? false),
                  Date().timeIntervalSince(self.lastContentAt) >= self.idleFadeAfter else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.4
                self.panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.armed,
                      // New content may have arrived (and re-revealed the
                      // panel) while the fade ran — don't yank it back out.
                      !(self.isBusy?() ?? false),
                      Date().timeIntervalSince(self.lastContentAt) >= self.idleFadeAfter else { return }
                self.panel.orderOut(nil)
            })
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    /// Briefly shows a status line (e.g. "● Recording") in the caption spot so
    /// starting/stopping has immediate visual feedback, then hides again after
    /// `duration` unless real speech text has replaced it.
    func flashStatus(_ text: String, duration: TimeInterval = 2.0) {
        flashGen &+= 1
        let myGen = flashGen
        textField.stringValue = text
        layout(for: text)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.flashGen == myGen else { return }
            // No speech arrived meanwhile — fade the badge back out.
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                self.panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.flashGen == myGen else { return }
                self.panel.orderOut(nil)
            })
        }
    }

    /// Splits into sentences on Korean/Latin/CJK sentence-ending punctuation,
    /// keeping the punctuation attached.
    private static func sentences(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ".?!。？！\n".contains(ch) {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { result.append(trimmed) }
        return result
    }

    /// One caption run's role in the karaoke model.
    enum CaptionStyle {
        /// Already voiced — white.
        case spoken
        /// Being voiced right now: characters up to `upTo` highlighted
        /// (the play head), the rest white.
        case speaking(upTo: Int)
        /// Not voiced yet (latest translation preview) — dimmed.
        case pending
    }

    /// Legacy two-tone entry point (LLM path, agreement captions).
    func update(pieces: [(text: String, isFinal: Bool)]) {
        update(styledPieces: pieces.map { ($0.text, $0.isFinal ? .spoken : .pending) })
    }

    /// Interpreter-mode captions: styled runs concatenated verbatim — line
    /// breaks arrive inside the run text. The karaoke highlight moves many
    /// times a second, so identical-text updates that only shift the
    /// highlight skip measuring/layout and just restyle the field.
    func update(styledPieces pieces: [(text: String, style: CaptionStyle)]) {
        guard armed else { return }
        guard pieces.contains(where: { $0.text.contains(where: { $0.isLetter || $0.isNumber }) }) else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let base: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
        let styled = NSMutableAttributedString()
        var highlightKey = 0
        for piece in pieces {
            switch piece.style {
            case .spoken:
                styled.append(NSAttributedString(string: piece.text, attributes:
                    base.merging([.foregroundColor: NSColor.white]) { a, _ in a }))
            case .speaking(let upTo):
                highlightKey = upTo
                let chars = Array(piece.text)
                let cut = max(0, min(chars.count, upTo))
                styled.append(NSAttributedString(string: String(chars[..<cut]), attributes:
                    base.merging([.foregroundColor: NSColor.systemYellow]) { a, _ in a }))
                styled.append(NSAttributedString(string: String(chars[cut...]), attributes:
                    base.merging([.foregroundColor: NSColor.white]) { a, _ in a }))
            case .pending:
                styled.append(NSAttributedString(string: piece.text, attributes:
                    base.merging([.foregroundColor: NSColor.white.withAlphaComponent(0.55)]) { a, _ in a }))
            }
        }
        // Same text + same highlight position: nothing to do. Same text
        // with a MOVED highlight: restyle only — measuring and reframing
        // the panel 10×/s would burn CPU for identical geometry. Only a
        // real content change resets the idle clock and re-reveals (so
        // repeated emits can't resurrect an idle-faded caption).
        if styled.string == lastContent {
            guard highlightKey != lastHighlight else { return }
            lastHighlight = highlightKey
            textField.attributedStringValue = styled
            return
        }
        lastContent = styled.string
        lastHighlight = highlightKey
        lastContentAt = Date()
        flashGen &+= 1
        textField.attributedStringValue = styled
        layout(for: styled.string)
        reveal()
    }

    /// Feeds the full accumulated transcript; the overlay shows only the tail,
    /// caption-style, and only once there is actual speech to show.
    func update(fullText: String) {
        guard armed else { return }
        // No captions until something was actually said.
        guard fullText.contains(where: { $0.isLetter || $0.isNumber }) else { return }
        // The transcriber already breaks the text into one utterance per
        // "\n". Split on those FIRST, take the last few, then re-join with
        // "\n". This prevents the old path where sentences() re-split and
        // re-joined, doubling line breaks whenever the raw text already
        // contained "\n" — the caption showed more spacing than the
        // transcript window as a result.
        let lines = fullText.split(separator: "\n", omittingEmptySubsequences: true)
        var tail = lines.suffix(maxLines).joined(separator: "\n")
        if tail.count > tailLength {
            // A single run-on sentence: fall back to a plain tail and let the
            // label wrap it. Snap to a word boundary only when one appears
            // near the cut — the old unconditional "drop through the first
            // space" left a single character (or nothing at all) whenever the
            // truncated chunk's only space sat near its end, which rendered
            // as an empty black box mid-speech.
            tail = String(tail.suffix(tailLength))
            if let space = tail.firstIndex(of: " "),
               tail.distance(from: tail.startIndex, to: space) <= 16 {
                let afterSpace = String(tail[tail.index(after: space)...])
                if afterSpace.count >= tailLength / 4 { tail = afterSpace }
            }
        }
        // Never replace a readable caption with an empty or token-sized one.
        guard tail.contains(where: { $0.isLetter || $0.isNumber }) else { return }
        guard tail != lastContent else { return }
        lastContent = tail
        lastContentAt = Date()
        // Real speech supersedes any status badge — cancel its auto-hide.
        flashGen &+= 1
        textField.stringValue = tail
        layout(for: tail.isEmpty ? " " : tail)
        reveal()
    }

    private func reveal() {
        guard !panel.isVisible || panel.alphaValue < 1 else { return }
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }
    }

    // MARK: - Layout

    private func layout(for text: String) {
        // Prefer the active screen so captions appear where the user is
        // looking (screens.first can be the closed built-in display when an
        // external monitor is the main one).
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let vis = screen.visibleFrame
        // Cap the caption width like real subtitles, but generously — turn
        // lines are whole utterances now and cramped wrapping (breaking a
        // Korean sentence before its final particle) reads terribly.
        let maxTextWidth = min(vis.width * 0.72, 1000) - hPadding * 2

        // Measure with boundingRect for the HEIGHT (sizeThatFits answers with
        // maximumNumberOfLines' worth of height regardless of content, which
        // gave a one-line caption a four-line box with the text sunk to the
        // bottom). boundingRect's width runs a couple of points narrower than
        // what NSTextField actually renders — that used to wrap every line's
        // last character — so measure against a slack-reduced width and hand
        // the field the slack back.
        let slack: CGFloat = 8
        let bounding = (text as NSString).boundingRect(
            with: NSSize(width: maxTextWidth - slack, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let textHeight = min(ceil(bounding.height), lineHeight * CGFloat(renderedLineCap))
        let textWidth = min(maxTextWidth, max(160, ceil(bounding.width) + slack))

        let boxWidth = textWidth + hPadding * 2
        let boxHeight = textHeight + vPadding * 2
        // The panel is oversized by the button overhang on the top and right.
        let width = boxWidth + overhang
        let height = boxHeight + overhang

        var frame = panel.frame
        frame.size = NSSize(width: width, height: height)
        // Center the caption box (not the oversized panel) on screen.
        frame.origin.x = vis.midX - boxWidth / 2
        frame.origin.y = vis.minY + bottomMargin

        // Subview frames FIRST, then the panel frame with display:true — the
        // reverse order redrew before the subviews moved, leaving the old
        // caption ghosted under the new one whenever the box changed size.
        captionBox.frame = NSRect(x: 0, y: 0, width: boxWidth, height: boxHeight)
        textField.frame = NSRect(x: hPadding, y: vPadding, width: textWidth, height: textHeight)
        // Close button centered exactly on the box's top-right corner point.
        closeButton.frame = NSRect(
            x: boxWidth - closeSize / 2,
            y: boxHeight - closeSize / 2,
            width: closeSize,
            height: closeSize
        )
        panel.setFrame(frame, display: true)
        container.needsDisplay = true
    }

    /// Container that reports mouse hover for the close-button reveal.
    private final class HoverView: NSView {
        var onHover: ((Bool) -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
        }

        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }
    }
}
