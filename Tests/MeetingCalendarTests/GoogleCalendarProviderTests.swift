import Foundation
@testable import MeetingCalendar
import MeetingCore
import Testing

@Suite("Google Calendar API", .serialized)
struct GoogleCalendarProviderTests {
    @Test("OAuth authorization URL이 PKCE와 calendar.events scope를 포함한다")
    func authorizationURLUsesPKCE() throws {
        let url = try GoogleCalendarOAuthClient.authorizationURL(
            configuration: GoogleCalendarOAuthConfiguration(clientID: "client.apps.googleusercontent.com"),
            redirectURI: "http://127.0.0.1:43123/oauth2callback",
            verifier: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~",
            state: "state-value"
        )
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.first(where: { $0.name == "scope" })?.value == GoogleCalendarOAuthConfiguration.calendarEventsScope)
        #expect(query.first(where: { $0.name == "code_challenge_method" })?.value == "S256")
        #expect(query.first(where: { $0.name == "code_challenge" })?.value?.isEmpty == false)
        #expect(query.first(where: { $0.name == "state" })?.value == "state-value")
    }

    @Test("events.list 응답을 CalendarEvent로 변환한다")
    func listsEvents() async throws {
        let store = MemoryTokenStore(tokens: MemoryTokenStore.valid)
        let recorder = URLProtocolRecorder { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/calendar/v3/calendars/primary/events")
            #expect(request.url?.query?.contains("singleEvents=true") == true)
            #expect(request.url?.query?.contains("orderBy=startTime") == true)
            return .json(
                """
                {
                  "summary": "Primary",
                  "timeZone": "Asia/Seoul",
                  "items": [
                    {
                      "id": "event-1",
                      "etag": "\\\"etag-1\\\"",
                      "status": "confirmed",
                      "summary": "제품 회의",
                      "description": "https://meet.google.com/abc-defg-hij",
                      "start": {"dateTime": "2026-08-24T10:00:00+09:00"},
                      "end": {"dateTime": "2026-08-24T11:00:00+09:00"},
                      "organizer": {"email": "host@example.com", "displayName": "주최자", "self": true},
                      "attendees": [
                        {"email": "host@example.com", "displayName": "주최자", "organizer": true, "self": true},
                        {"email": "guest@example.com", "displayName": "참석자"}
                      ],
                      "reminders": {"useDefault": false, "overrides": [{"method": "popup", "minutes": 10}]}
                    }
                  ]
                }
                """
            )
        }
        let provider = makeProvider(store: store, recorder: recorder)

        let events = try await provider.events(
            from: Date(timeIntervalSince1970: 1_777_000_000),
            to: Date(timeIntervalSince1970: 1_778_000_000)
        )

        let event = try #require(events.first)
        #expect(event.id == "event-1")
        #expect(event.title == "제품 회의")
        #expect(event.calendarTitle == "Primary")
        #expect(event.attendeeDisplayNames == ["주최자", "참석자"])
        #expect(event.earliestAlarmLeadTime == 600)
        #expect(event.conferenceURL?.host == "meet.google.com")
        #expect(event.etag == "\"etag-1\"")
    }

    @Test("이벤트를 생성하고 Google 응답을 반환한다")
    func createsEvent() async throws {
        let recorder = URLProtocolRecorder { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/calendar/v3/calendars/primary/events")
            #expect(request.url?.query?.contains("sendUpdates=all") == true)
            let body = try #require(request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])
            #expect(body["summary"] as? String == "새 일정")
            return .json(Self.eventJSON(id: "created-1", title: "새 일정"))
        }
        let provider = makeProvider(store: .init(tokens: MemoryTokenStore.valid), recorder: recorder)

        let event = try await provider.createEvent(
            CalendarEventDraft(
                title: "새 일정",
                startDate: Date(timeIntervalSince1970: 1_777_000_000),
                endDate: Date(timeIntervalSince1970: 1_777_003_600),
                attendees: [CalendarAttendeeInput(email: "guest@example.com")]
            ),
            notification: .all
        )

        #expect(event.id == "created-1")
        #expect(event.title == "새 일정")
    }

    @Test("이벤트 수정은 최신 ETag를 읽은 뒤 PATCH한다")
    func updatesEventWithETag() async throws {
        let recorder = URLProtocolRecorder { request in
            if request.httpMethod == "GET" {
                #expect(request.url?.path == "/calendar/v3/calendars/primary/events/event-1")
                return .json(Self.eventJSON(id: "event-1", title: "기존 일정", etag: "\"old\""))
            }
            #expect(request.httpMethod == "PATCH")
            #expect(request.allHTTPHeaderFields?["If-Match"] == "\"old\"")
            let body = try #require(request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])
            #expect(body["summary"] as? String == "수정 일정")
            return .json(Self.eventJSON(id: "event-1", title: "수정 일정", etag: "\"new\""))
        }
        let provider = makeProvider(store: .init(tokens: MemoryTokenStore.valid), recorder: recorder)

        let event = try await provider.updateEvent(
            id: "event-1",
            changes: CalendarEventPatch(title: .set("수정 일정")),
            notification: .none
        )

        #expect(event.title == "수정 일정")
        #expect(event.etag == "\"new\"")
    }

    @Test("이벤트 삭제는 sendUpdates 정책을 전달한다")
    func deletesEvent() async throws {
        let recorder = URLProtocolRecorder { request in
            #expect(request.httpMethod == "DELETE")
            #expect(request.url?.path == "/calendar/v3/calendars/primary/events/event-1")
            #expect(request.url?.query?.contains("sendUpdates=none") == true)
            return .response(status: 204, data: Data())
        }
        let provider = makeProvider(store: .init(tokens: MemoryTokenStore.valid), recorder: recorder)

        try await provider.deleteEvent(id: "event-1", notification: .none)
    }

    @Test("만료된 access token은 refresh token으로 갱신한다")
    func refreshesExpiredToken() async throws {
        let store = MemoryTokenStore(tokens: MemoryTokenStore.expired)
        let recorder = URLProtocolRecorder { request in
            #expect(request.url?.absoluteString == "https://oauth.test/token")
            #expect(request.httpMethod == "POST")
            return .json(
                """
                {"access_token":"new-access","expires_in":3600,"token_type":"Bearer"}
                """
            )
        }
        let oauth = makeOAuth(store: store, recorder: recorder)

        let token = try await oauth.accessToken()

        #expect(token == "new-access")
        #expect(store.tokens?.accessToken == "new-access")
    }

    private func makeProvider(store: MemoryTokenStore, recorder: URLProtocolRecorder) -> GoogleCalendarProvider {
        GoogleCalendarProvider(
            oauth: makeOAuth(store: store, recorder: recorder),
            session: recorder.session,
            apiBaseURL: URL(string: "https://calendar.test/calendar/v3")!
        )
    }

    private func makeOAuth(store: MemoryTokenStore, recorder: URLProtocolRecorder) -> GoogleCalendarOAuthClient {
        GoogleCalendarOAuthClient(
            configuration: GoogleCalendarOAuthConfiguration(
                clientID: "client.apps.googleusercontent.com",
                tokenEndpoint: URL(string: "https://oauth.test/token")!,
                revokeEndpoint: URL(string: "https://oauth.test/revoke")!
            ),
            tokenStore: store,
            session: recorder.session,
            openURL: { _ in false }
        )
    }

    private static func eventJSON(
        id: String,
        title: String,
        etag: String = "\"etag\""
    ) -> String {
        """
        {
          "id": "\(id)",
          "etag": "\(etag.replacingOccurrences(of: "\"", with: "\\\""))",
          "status": "confirmed",
          "summary": "\(title)",
          "start": {"dateTime": "2026-08-24T10:00:00+09:00"},
          "end": {"dateTime": "2026-08-24T11:00:00+09:00"}
        }
        """
    }
}

private final class MemoryTokenStore: GoogleCalendarTokenStore, @unchecked Sendable {
    var tokens: GoogleOAuthTokens?

    init(tokens: GoogleOAuthTokens?) {
        self.tokens = tokens
    }

    func load() throws -> GoogleOAuthTokens? { tokens }

    func save(_ tokens: GoogleOAuthTokens) throws {
        self.tokens = tokens
    }

    func delete() throws {
        tokens = nil
    }

    static let valid = GoogleOAuthTokens(
        accessToken: "access",
        refreshToken: "refresh",
        expirationDate: Date().addingTimeInterval(3600)
    )

    static let expired = GoogleOAuthTokens(
        accessToken: "expired",
        refreshToken: "refresh",
        expirationDate: Date().addingTimeInterval(-60)
    )
}

private final class URLProtocolRecorder: URLProtocol, @unchecked Sendable {
    struct Result {
        let status: Int
        let headers: [String: String]
        let data: Data

        static func json(_ string: String, status: Int = 200) -> Result {
            Result(status: status, headers: ["Content-Type": "application/json"], data: Data(string.utf8))
        }

        static func response(status: Int, data: Data) -> Result {
            Result(status: status, headers: [:], data: data)
        }
    }

    private nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> Result)?

    init(handler: @escaping @Sendable (URLRequest) throws -> Result) {
        Self.handler = handler
        super.init(request: URLRequest(url: URL(string: "https://calendar.test")!), cachedResponse: nil, client: nil)
    }

    /// URLSession이 요청마다 이 초기화로 인스턴스를 만든다. 지정 초기화를 추가하면 상속이 끊기므로 직접 넘긴다.
    override init(request: URLRequest, cachedResponse: CachedURLResponse?, client: (any URLProtocolClient)?) {
        super.init(request: request, cachedResponse: cachedResponse, client: client)
    }

    var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Self.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            // URLSession은 URLProtocol에 넘길 때 httpBody를 httpBodyStream으로 바꾼다. 검증용으로 되돌린다.
            var request = request
            if request.httpBody == nil, let stream = request.httpBodyStream {
                request.httpBody = Self.readAll(stream)
            }
            let result = try Self.handler!(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: result.status,
                httpVersion: nil,
                headerFields: result.headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
