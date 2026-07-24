import AppKit

/// Modal sheet listing upcoming calendar events, each with a checkbox. Checked
/// events are saved to `Settings.calendarSelectedEventIDs` for auto-recording.
/// The settings UI has no table/list control, so this is a scrollable stack of
/// checkboxes laid out by absolute coordinates, matching the app's convention.
enum CalendarPickerSheet {
    static func present(over parent: NSWindow, onDone: @escaping () -> Void) {
        let controller = PickerController()
        controller.onDone = onDone
        parent.beginSheet(controller.window) { _ in
            _ = controller // retain the controller until the sheet ends
        }
        controller.load()
    }
}

/// Top-origin container so rows stack downward naturally.
private final class FlippedView: NSView { override var isFlipped: Bool { true } }

private final class PickerController {
    let window: NSWindow
    var onDone: (() -> Void)?
    private let scroll = NSScrollView()
    private let doc = FlippedView()
    private let statusLabel = NSTextField(labelWithString: "회의 목록을 불러오는 중…")
    private var checks: [(id: String, box: NSButton)] = []

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "자동 녹음할 회의 선택"
        let content = window.contentView!

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.frame = NSRect(x: 20, y: 384, width: 420, height: 20)
        content.addSubview(statusLabel)

        scroll.frame = NSRect(x: 20, y: 60, width: 420, height: 314)
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = doc
        content.addSubview(scroll)

        let done = NSButton(title: "완료", target: self, action: #selector(doneTapped))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.frame = NSRect(x: 360, y: 16, width: 84, height: 30)
        content.addSubview(done)
    }

    func load() {
        GoogleCalendar.upcomingEvents { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let events): self.populate(events)
                case .failure(let error):
                    self.statusLabel.stringValue = "불러오기 실패: \(error.localizedDescription)"
                }
            }
        }
    }

    private func populate(_ events: [GoogleCalendar.CalendarEvent]) {
        let selected = Set(Settings.shared.calendarSelectedEventIDs)
        let fmt = DateFormatter()
        fmt.dateFormat = "M/d(E) HH:mm"
        fmt.locale = Locale(identifier: "ko_KR")
        statusLabel.stringValue = events.isEmpty
            ? "다가오는 회의가 없습니다."
            : "\(events.count)개 회의 — 자동 녹음할 항목을 체크하세요."

        let rowH: CGFloat = 28
        doc.frame = NSRect(x: 0, y: 0, width: 400, height: max(1, CGFloat(events.count) * rowH))
        for (i, ev) in events.enumerated() {
            let title = "\(fmt.string(from: ev.start))  \(ev.title)"
            let box = NSButton(checkboxWithTitle: title, target: self, action: #selector(checkToggled(_:)))
            box.state = selected.contains(ev.id) ? .on : .off
            box.frame = NSRect(x: 8, y: CGFloat(i) * rowH, width: 384, height: rowH - 4)
            doc.addSubview(box)
            checks.append((ev.id, box))
        }
    }

    @objc private func checkToggled(_ sender: NSButton) {
        guard let entry = checks.first(where: { $0.box === sender }) else { return }
        var selected = Set(Settings.shared.calendarSelectedEventIDs)
        if sender.state == .on { selected.insert(entry.id) } else { selected.remove(entry.id) }
        Settings.shared.calendarSelectedEventIDs = Array(selected)
    }

    @objc private func doneTapped() {
        window.sheetParent?.endSheet(window)
        onDone?()
    }
}
