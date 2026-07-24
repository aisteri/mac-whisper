import AppKit
import Foundation

/// Watches the user's selected calendar events and fires `onFire` when one is
/// about to start (or is already in progress after the laptop wakes). Polls the
/// calendar periodically and re-checks on wake, so a meeting missed while the
/// lid was closed still starts when the machine comes back.
final class CalendarScheduler {
    /// Called on the main thread when a selected event should start recording.
    var onFire: ((GoogleCalendar.CalendarEvent) -> Void)?

    private var events: [GoogleCalendar.CalendarEvent] = []
    /// Instance IDs already fired, so one event never starts twice.
    private var firedEventIDs: Set<String> = []
    private var refreshTimer: Timer?
    private var checkTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    /// How often to re-list the calendar, and how often to check for a due
    /// event against the cached list.
    private let refreshInterval: TimeInterval = 15 * 60
    private let checkInterval: TimeInterval = 60

    // MARK: - Lifecycle

    /// Starts polling + wake observation. Idempotent — safe to call on settings
    /// changes; it restarts cleanly. No-op unless connected and enabled.
    func start() {
        stop()
        guard Settings.shared.calendarAutoRecordEnabled, GoogleOAuth.shared.isSignedIn else { return }
        SpeechService.diag("calendar scheduler start")
        refreshEvents()

        let refresh = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshEvents()
        }
        RunLoop.main.add(refresh, forMode: .common)
        refreshTimer = refresh

        let check = Timer(timeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.checkDue()
        }
        RunLoop.main.add(check, forMode: .common)
        checkTimer = check

        // Catch meetings missed while asleep: on wake, re-list and check now.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            SpeechService.diag("calendar scheduler wake — re-checking")
            self?.refreshEvents()
        }
    }

    func stop() {
        refreshTimer?.invalidate(); refreshTimer = nil
        checkTimer?.invalidate(); checkTimer = nil
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            wakeObserver = nil
        }
    }

    // MARK: - Polling + firing

    private func refreshEvents() {
        GoogleCalendar.upcomingEvents { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let events):
                    self.events = events
                    SpeechService.diag("calendar refreshed: \(events.count) upcoming events")
                    // A fresh list may already contain a due event (e.g. right
                    // after wake), so check immediately.
                    self.checkDue()
                case .failure(let error):
                    SpeechService.diag("calendar refresh FAILED: \(error.localizedDescription)")
                }
            }
        }
    }

    private func checkDue(now: Date = Date()) {
        let selected = Set(Settings.shared.calendarSelectedEventIDs)
        let lead = TimeInterval(Settings.shared.calendarLeadMinutes * 60)
        let isRecording = (NSApp.delegate as? AppDelegate)?.isLockedRecordingPublic ?? false
        for event in events where selected.contains(event.id) {
            if Self.shouldFire(event: event, now: now, lead: lead,
                               fired: firedEventIDs, isRecording: isRecording) {
                firedEventIDs.insert(event.id)
                SpeechService.diag("calendar FIRE '\(event.title)' start=\(event.start)")
                onFire?(event)
                return // one at a time; the recording guard covers the rest
            }
        }
    }

    /// Pure firing rule (unit-tested): fire once, from `lead` before the start
    /// until the end, only when nothing is already recording.
    static func shouldFire(event: GoogleCalendar.CalendarEvent, now: Date,
                           lead: TimeInterval, fired: Set<String>, isRecording: Bool) -> Bool {
        guard !fired.contains(event.id) else { return false }
        guard !isRecording else { return false }
        return now >= event.start.addingTimeInterval(-lead) && now < event.end
    }
}
