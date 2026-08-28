import Foundation
import MeetingCore

/// Slack Web API 클라이언트.
///
/// HTTP는 `MeetingPublishing` 안에서만 나간다. 회의 오디오·전사문·근거 타임스탬프는
/// 여기까지 오지 않는다(`SlackActionPayload`에 담을 수 없다).
/// 로깅에서 Authorization 헤더와 토큰·본문은 항상 제외한다.
///
/// **모델은 이 타입을 호출하지 않는다.** 추론 모듈에는 Slack 의존성이 없다.
public protocol SlackMessaging: Sendable {
    func postMessage(channel: String, text: String) async throws -> SlackPostedMessage
}

public struct SlackPostedMessage: Hashable, Sendable {
    public var channel: String
    public var timestamp: String

    public init(channel: String, timestamp: String) {
        self.channel = channel
        self.timestamp = timestamp
    }
}

public actor SlackClient: SlackMessaging {
    private let credentials: SlackCredentials
    private let session: URLSession
    private let log: (@Sendable (String) -> Void)?

    public init(
        credentials: SlackCredentials,
        session: URLSession = .shared,
        log: (@Sendable (String) -> Void)? = nil
    ) {
        self.credentials = credentials
        self.session = session
        self.log = log
    }

    public func postMessage(channel: String, text: String) async throws -> SlackPostedMessage {
        let response = try await send(
            method: "chat.postMessage",
            body: [
                "channel": channel,
                "text": text,
                "unfurl_links": false,
                "unfurl_media": false
            ]
        )
        let postedChannel = response["channel"] as? String ?? channel
        guard let timestamp = response["ts"] as? String else {
            throw PublishError.invalidResponse("Slack 메시지 ts 없음")
        }
        return SlackPostedMessage(channel: postedChannel, timestamp: timestamp)
    }

    /// 연결 확인용. 팀·사용자 이름만 반환하고 토큰은 남기지 않는다.
    public func verifyConnection() async throws -> String {
        let response = try await send(method: "auth.test", body: [:])
        let user = response["user"] as? String ?? "확인됨"
        if let team = response["team"] as? String, !team.isEmpty {
            return "\(user) @ \(team)"
        }
        return user
    }

    private func send(method: String, body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: "https://slack.com/api/\(method)") else {
            throw PublishError.missingSlackCredentials("Slack API 주소를 만들 수 없습니다.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(credentials.authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        // 로그에는 메서드 이름만 남긴다. 헤더·본문은 남기지 않는다.
        log?(method)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PublishError.invalidResponse("HTTP 응답이 아닙니다.")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let message = String(decoding: data.prefix(500), as: UTF8.self)
            throw PublishError.slackAPI(status: http.statusCode, message: message)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PublishError.invalidResponse(String(decoding: data.prefix(200), as: UTF8.self))
        }
        if let ok = object["ok"] as? Bool, ok {
            return object
        }
        let error = object["error"] as? String ?? String(decoding: data.prefix(200), as: UTF8.self)
        throw PublishError.slackAPI(status: http.statusCode, message: error)
    }
}
