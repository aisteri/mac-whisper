import Foundation

/// Minimal Google Calendar read access for the auto-record scheduler: lists
/// upcoming timed events on the primary calendar. Read-only; uses the OAuth
/// access token from `GoogleOAuth`.
enum GoogleCalendar {
    struct CalendarEvent: Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
    }

    struct CalendarError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Fetches timed events on the primary calendar from now through `within`.
    /// All-day events (which carry a `date` but no `dateTime`) are skipped — the
    /// scheduler only records events with a real start time. `singleEvents=true`
    /// expands recurring series into individual instances, each with its own id.
    static func upcomingEvents(within: TimeInterval = 7 * 86400,
                               completion: @escaping (Result<[CalendarEvent], Error>) -> Void) {
        GoogleOAuth.shared.withFreshToken { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let access):
                fetch(access: access, within: within, completion: completion)
            }
        }
    }

    private static func fetch(access: String, within: TimeInterval,
                              completion: @escaping (Result<[CalendarEvent], Error>) -> Void) {
        let iso = ISO8601DateFormatter()
        let now = Date()
        var comps = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        comps.queryItems = [
            URLQueryItem(name: "timeMin", value: iso.string(from: now)),
            URLQueryItem(name: "timeMax", value: iso.string(from: now.addingTimeInterval(within))),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "50"),
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let detail = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                completion(.failure(CalendarError(message: "캘린더 요청 실패 (HTTP \(status)): \(detail)")))
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]] else {
                completion(.failure(CalendarError(message: "캘린더 응답 형식 오류")))
                return
            }
            completion(.success(parse(items: items)))
        }.resume()
    }

    /// Exposed for testing: turns the raw `items` array into timed events,
    /// dropping all-day and unparseable entries.
    static func parse(items: [[String: Any]]) -> [CalendarEvent] {
        let iso = ISO8601DateFormatter()
        return items.compactMap { item in
            guard let id = item["id"] as? String,
                  let start = item["start"] as? [String: Any],
                  let end = item["end"] as? [String: Any],
                  let startStr = start["dateTime"] as? String,   // nil for all-day
                  let endStr = end["dateTime"] as? String,
                  let startDate = iso.date(from: startStr),
                  let endDate = iso.date(from: endStr) else {
                return nil
            }
            let title = (item["summary"] as? String) ?? "(제목 없음)"
            return CalendarEvent(id: id, title: title, start: startDate, end: endDate)
        }
    }
}
