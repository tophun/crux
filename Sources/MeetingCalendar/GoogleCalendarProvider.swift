import Foundation
import MeetingCore

/// Google Calendar v3 REST API 기반 캘린더 제공자.
///
/// 기본 캘린더(`primary`)를 읽고, 명시적 사용자 승인 뒤 일정 CRUD를 수행한다.
public final class GoogleCalendarProvider: CalendarProvider, CalendarEventWriter, @unchecked Sendable {
    public static let primaryCalendarID = "primary"
    public static let defaultAPIBaseURL = URL(string: "https://www.googleapis.com/calendar/v3")!

    private let oauth: GoogleCalendarOAuthClient
    private let session: URLSession
    private let apiBaseURL: URL

    public init(
        oauth: GoogleCalendarOAuthClient,
        session: URLSession = .shared,
        apiBaseURL: URL = GoogleCalendarProvider.defaultAPIBaseURL
    ) {
        self.oauth = oauth
        self.session = session
        self.apiBaseURL = apiBaseURL
    }

    public convenience init(
        configuration: GoogleCalendarOAuthConfiguration,
        tokenStore: any GoogleCalendarTokenStore = GoogleCalendarKeychainTokenStore(),
        session: URLSession = .shared,
        apiBaseURL: URL = GoogleCalendarProvider.defaultAPIBaseURL
    ) {
        self.init(
            oauth: GoogleCalendarOAuthClient(
                configuration: configuration,
                tokenStore: tokenStore,
                session: session
            ),
            session: session,
            apiBaseURL: apiBaseURL
        )
    }

    public func authorizationStatus() -> CalendarAuthorizationStatus {
        oauth.authorizationStatus
    }

    public func requestAccess() async throws -> Bool {
        try await oauth.requestAccess()
    }

    public func disconnect() async throws {
        try await oauth.disconnect()
    }

    public func events(from: Date, to: Date) async throws -> [CalendarEvent] {
        var pageToken: String?
        var output: [CalendarEvent] = []
        repeat {
            var query = [
                URLQueryItem(name: "timeMin", value: Self.rfc3339(from)),
                URLQueryItem(name: "timeMax", value: Self.rfc3339(to)),
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "orderBy", value: "startTime"),
                URLQueryItem(name: "showDeleted", value: "false"),
                URLQueryItem(name: "maxResults", value: "2500"),
                URLQueryItem(name: "timeZone", value: TimeZone.current.identifier)
            ]
            if let pageToken {
                query.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            let response = try await send(
                method: "GET",
                path: ["calendars", Self.primaryCalendarID, "events"],
                query: query
            )
            let page = try decode(GoogleEventsResponse.self, from: response.data)
            output += (page.items ?? []).compactMap { Self.map($0, calendarTitle: page.summary, timeZone: page.timeZone) }
            pageToken = page.nextPageToken
        } while pageToken != nil
        return output
    }

    public func createEvent(
        _ draft: CalendarEventDraft,
        notification: CalendarNotificationPolicy
    ) async throws -> CalendarEvent {
        let response = try await send(
            method: "POST",
            path: ["calendars", Self.primaryCalendarID, "events"],
            query: [URLQueryItem(name: "sendUpdates", value: notification.rawValue)],
            body: Self.body(for: draft)
        )
        guard let event = try Self.map(
            decode(GoogleEventResource.self, from: response.data),
            calendarTitle: "기본 캘린더",
            timeZone: draft.timeZoneIdentifier
        ) else { throw GoogleCalendarError.invalidResponse("생성된 일정의 시작·종료 시각") }
        return event
    }

    public func updateEvent(
        id: String,
        changes: CalendarEventPatch,
        notification: CalendarNotificationPolicy
    ) async throws -> CalendarEvent {
        let currentResponse = try await send(
            method: "GET",
            path: ["calendars", Self.primaryCalendarID, "events", id]
        )
        let current = try decode(GoogleEventResource.self, from: currentResponse.data)
        let body = try Self.patchBody(changes, current: current)
        guard !body.isEmpty else {
            guard let event = Self.map(current, calendarTitle: "기본 캘린더", timeZone: current.start?.timeZone) else {
                throw GoogleCalendarError.invalidResponse("기존 일정의 시작·종료 시각")
            }
            return event
        }

        guard let etag = current.etag, !etag.isEmpty else {
            throw GoogleCalendarError.invalidResponse("수정 전 일정의 ETag")
        }
        let headers = ["If-Match": etag]
        let response = try await send(
            method: "PATCH",
            path: ["calendars", Self.primaryCalendarID, "events", id],
            query: [URLQueryItem(name: "sendUpdates", value: notification.rawValue)],
            body: body,
            headers: headers
        )
        guard let event = try Self.map(
            decode(GoogleEventResource.self, from: response.data),
            calendarTitle: "기본 캘린더",
            timeZone: current.start?.timeZone
        ) else { throw GoogleCalendarError.invalidResponse("수정된 일정의 시작·종료 시각") }
        return event
    }

    public func deleteEvent(
        id: String,
        notification: CalendarNotificationPolicy
    ) async throws {
        _ = try await send(
            method: "DELETE",
            path: ["calendars", Self.primaryCalendarID, "events", id],
            query: [URLQueryItem(name: "sendUpdates", value: notification.rawValue)]
        )
    }

    // MARK: - HTTP

    private struct APIResponse: Sendable {
        var data: Data
        var statusCode: Int
    }

    private func send(
        method: String,
        path: [String],
        query: [URLQueryItem] = [],
        body: [String: Any]? = nil,
        headers: [String: String] = [:]
    ) async throws -> APIResponse {
        func attempt(forceRefresh: Bool) async throws -> APIResponse {
            try await perform(
                method: method,
                path: path,
                query: query,
                body: body,
                headers: headers,
                accessToken: oauth.accessToken(forceRefresh: forceRefresh)
            )
        }
        var response = try await attempt(forceRefresh: false)
        if response.statusCode == 401 {
            response = try await attempt(forceRefresh: true)
        }
        return try checked(response)
    }

    private func perform(
        method: String,
        path: [String],
        query: [URLQueryItem],
        body: [String: Any]?,
        headers: [String: String],
        accessToken: String
    ) async throws -> APIResponse {
        var url = apiBaseURL
        for component in path {
            url.appendPathComponent(component)
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw GoogleCalendarError.invalidResponse("요청 URL")
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let requestURL = components.url else {
            throw GoogleCalendarError.invalidResponse("요청 URL")
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GoogleCalendarError.invalidResponse("HTTP 응답")
        }
        return APIResponse(data: data, statusCode: http.statusCode)
    }

    private func checked(_ response: APIResponse) throws -> APIResponse {
        guard (200 ..< 300).contains(response.statusCode) else {
            if response.statusCode == 409 || response.statusCode == 412 {
                throw GoogleCalendarError.conflict
            }
            let message = String(decoding: response.data.prefix(1000), as: UTF8.self)
            throw GoogleCalendarError.api(status: response.statusCode, message: message)
        }
        return response
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw GoogleCalendarError.invalidResponse("JSON 해석 실패")
        }
    }
}

// MARK: - Google Calendar resource mapping

private struct GoogleEventsResponse: Decodable {
    var summary: String?
    var timeZone: String?
    var nextPageToken: String?
    var items: [GoogleEventResource]?
}

private struct GoogleEventResource: Codable {
    var id: String?
    var etag: String?
    var status: String?
    var summary: String?
    var description: String?
    var location: String?
    var htmlLink: String?
    var hangoutLink: String?
    var start: GoogleDateTime?
    var end: GoogleDateTime?
    var organizer: GoogleAttendee?
    var attendees: [GoogleAttendee]?
    var conferenceData: GoogleConferenceData?
    var reminders: GoogleReminders?
    var recurringEventId: String?
    var originalStartTime: GoogleDateTime?
}

private struct GoogleDateTime: Codable {
    var date: String?
    var dateTime: String?
    var timeZone: String?
}

private struct GoogleAttendee: Codable {
    var email: String?
    var displayName: String?
    var organizer: Bool?
    var selfAttendee: Bool?
    var optional: Bool?

    enum CodingKeys: String, CodingKey {
        case email
        case displayName
        case organizer
        case selfAttendee = "self"
        case optional
    }
}

private struct GoogleConferenceData: Codable {
    var entryPoints: [GoogleConferenceEntryPoint]?
}

private struct GoogleConferenceEntryPoint: Codable {
    var entryPointType: String?
    var uri: String?
}

private struct GoogleReminders: Codable {
    var useDefault: Bool?
    var overrides: [GoogleReminder]?
}

private struct GoogleReminder: Codable {
    var method: String?
    var minutes: Int?
}

private extension GoogleCalendarProvider {
    static func map(
        _ resource: GoogleEventResource,
        calendarTitle: String?,
        timeZone: String?
    ) -> CalendarEvent? {
        guard let id = resource.id,
              let start = resource.start,
              let end = resource.end,
              let startValue = parse(start, fallbackTimeZone: timeZone),
              let endValue = parse(end, fallbackTimeZone: timeZone)
        else { return nil }

        let organizer = resource.organizer.map { attendee in
            EventAttendee(
                name: attendee.displayName,
                email: attendee.email,
                isOrganizer: true,
                isCurrentUser: attendee.selfAttendee == true
            )
        }
        var attendees = (resource.attendees ?? []).compactMap { attendee -> EventAttendee? in
            guard attendee.email != nil || attendee.displayName != nil else { return nil }
            return EventAttendee(
                name: attendee.displayName,
                email: attendee.email,
                isOrganizer: attendee.organizer == true,
                isCurrentUser: attendee.selfAttendee == true
            )
        }
        if let organizer,
           !attendees.contains(where: { $0.email == organizer.email && organizer.email != nil }) {
            attendees.insert(organizer, at: 0)
        }

        let conferenceCandidates = [resource.hangoutLink]
            + (resource.conferenceData?.entryPoints ?? []).compactMap(\.uri)
            + [resource.location, resource.description]
        let alarmOffsets = (resource.reminders?.overrides ?? []).compactMap { reminder -> TimeInterval? in
            guard let minutes = reminder.minutes else { return nil }
            return -Double(minutes) * 60
        }

        return CalendarEvent(
            id: id,
            seriesId: resource.recurringEventId,
            title: resource.summary ?? "제목 없는 일정",
            startDate: startValue.date,
            endDate: endValue.date,
            isAllDay: startValue.isAllDay,
            status: status(resource.status),
            attendees: attendees,
            conferenceURL: ConferenceLinkExtractor.extract(from: conferenceCandidates),
            location: resource.location,
            organizer: organizer,
            calendarTitle: calendarTitle,
            source: .google,
            etag: resource.etag,
            recurringEventId: resource.recurringEventId,
            originalStartDate: resource.originalStartTime.flatMap {
                parse($0, fallbackTimeZone: timeZone)?.date
            },
            alarmOffsets: alarmOffsets
        )
    }

    static func status(_ status: String?) -> CalendarEventStatus {
        switch status {
        case "confirmed": .confirmed
        case "tentative": .tentative
        case "cancelled": .canceled
        default: .unknown
        }
    }

    static func parse(
        _ value: GoogleDateTime,
        fallbackTimeZone: String?
    ) -> (date: Date, isAllDay: Bool)? {
        if let dateTime = value.dateTime, let date = parseISO8601(dateTime) {
            return (date, false)
        }
        guard let dateOnly = value.date else { return nil }
        guard let date = dayFormatter(timeZoneIdentifier: value.timeZone ?? fallbackTimeZone).date(from: dateOnly) else {
            return nil
        }
        return (date, true)
    }

    /// 종일 일정의 `yyyy-MM-dd` 값을 읽고 쓰는 포매터. 시간대가 없으면 현재 시간대로 해석한다.
    static func dayFormatter(timeZoneIdentifier: String?) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier ?? "") ?? .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    static func parseISO8601(_ value: String) -> Date? {
        fractionalISO8601.date(from: value) ?? standardISO8601.date(from: value)
    }

    static func rfc3339(_ date: Date) -> String {
        fractionalISO8601.string(from: date)
    }

    /// ISO8601DateFormatter는 스레드 안전하다. 이벤트마다 새로 만들지 않고 재사용한다.
    private nonisolated(unsafe) static let fractionalISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let standardISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func body(for draft: CalendarEventDraft) -> [String: Any] {
        var body: [String: Any] = [
            "summary": draft.title,
            "start": dateBody(
                date: draft.startDate,
                isAllDay: draft.isAllDay,
                timeZoneIdentifier: draft.timeZoneIdentifier
            ),
            "end": dateBody(
                date: draft.endDate,
                isAllDay: draft.isAllDay,
                timeZoneIdentifier: draft.timeZoneIdentifier
            )
        ]
        if let description = draft.description {
            body["description"] = description
        }
        if let location = draft.location {
            body["location"] = location
        }
        if !draft.attendees.isEmpty {
            body["attendees"] = attendeesBody(draft.attendees)
        }
        return body
    }

    static func patchBody(
        _ changes: CalendarEventPatch,
        current: GoogleEventResource
    ) throws -> [String: Any] {
        var body: [String: Any] = [:]
        apply(changes.title, key: "summary", to: &body)
        apply(changes.description, key: "description", to: &body)
        apply(changes.location, key: "location", to: &body)
        switch changes.attendees {
        case .unchanged: break
        case let .set(attendees): body["attendees"] = attendeesBody(attendees)
        case .clear: body["attendees"] = []
        }

        let currentStart = current.start.flatMap { parse($0, fallbackTimeZone: $0.timeZone) }
        let currentEnd = current.end.flatMap { parse($0, fallbackTimeZone: $0.timeZone) }
        var startDate = currentStart?.date
        var endDate = currentEnd?.date
        var isAllDay = currentStart?.isAllDay ?? false
        var timeZone = current.start?.timeZone

        switch changes.startDate {
        case .unchanged: break
        case let .set(value): startDate = value
        case .clear: throw GoogleCalendarError.invalidResponse("시작 시각은 삭제할 수 없습니다.")
        }
        switch changes.endDate {
        case .unchanged: break
        case let .set(value): endDate = value
        case .clear: throw GoogleCalendarError.invalidResponse("종료 시각은 삭제할 수 없습니다.")
        }
        switch changes.isAllDay {
        case .unchanged: break
        case let .set(value): isAllDay = value
        case .clear: throw GoogleCalendarError.invalidResponse("종일 여부는 삭제할 수 없습니다.")
        }
        switch changes.timeZoneIdentifier {
        case .unchanged: break
        case let .set(value): timeZone = value
        case .clear: timeZone = nil
        }
        let dateChanged = changes.startDate != .unchanged
            || changes.endDate != .unchanged
            || changes.isAllDay != .unchanged
            || changes.timeZoneIdentifier != .unchanged
        if dateChanged {
            guard let startDate, let endDate else {
                throw GoogleCalendarError.invalidResponse("수정할 일정의 시작·종료 시각")
            }
            body["start"] = dateBody(date: startDate, isAllDay: isAllDay, timeZoneIdentifier: timeZone)
            body["end"] = dateBody(date: endDate, isAllDay: isAllDay, timeZoneIdentifier: timeZone)
        }
        return body
    }

    static func apply(
        _ update: CalendarFieldUpdate<some Hashable & Sendable>,
        key: String,
        to body: inout [String: Any]
    ) {
        switch update {
        case .unchanged: break
        case let .set(value): body[key] = value
        case .clear: body[key] = ""
        }
    }

    static func dateBody(date: Date, isAllDay: Bool, timeZoneIdentifier: String?) -> [String: Any] {
        if isAllDay {
            return ["date": dayFormatter(timeZoneIdentifier: timeZoneIdentifier).string(from: date)]
        }
        var body: [String: Any] = ["dateTime": rfc3339(date)]
        if let timeZoneIdentifier {
            body["timeZone"] = timeZoneIdentifier
        }
        return body
    }

    static func attendeesBody(_ attendees: [CalendarAttendeeInput]) -> [[String: Any]] {
        attendees.map { attendee in
            var body: [String: Any] = ["email": attendee.email]
            if let displayName = attendee.displayName {
                body["displayName"] = displayName
            }
            if attendee.optional {
                body["optional"] = true
            }
            return body
        }
    }
}
