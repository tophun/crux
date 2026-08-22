import Foundation

public enum CalendarAuthorizationStatus: String, Sendable, CaseIterable {
    case notDetermined
    case denied
    case restricted
    case authorized
    /// 쓰기 전용 권한 — 일정을 읽을 수 없다
    case writeOnly

    public var canReadEvents: Bool { self == .authorized }

    public var displayName: String {
        switch self {
        case .notDetermined: "확인 필요"
        case .denied: "거부됨"
        case .restricted: "제한됨"
        case .authorized: "허용됨"
        case .writeOnly: "읽기 권한 없음"
        }
    }
}

/// 캘린더 읽기 추상화. 구현은 교체 가능하다.
///
/// 현재 구현은 EventKit(macOS 캘린더)이다. macOS 캘린더에 Google 계정을 추가해 두면
/// Google Calendar 일정을 네트워크 요청 없이 읽는다.
public protocol CalendarProvider: Sendable {
    func authorizationStatus() -> CalendarAuthorizationStatus
    /// 권한을 요청한다. 이미 허용돼 있으면 즉시 true.
    func requestAccess() async throws -> Bool
    func events(from: Date, to: Date) async throws -> [CalendarEvent]
}

/// 회의 링크 추출. 캘린더 필드에 흩어져 있는 회의 URL을 찾는다.
public enum ConferenceLinkExtractor {
    static let hosts = [
        "zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com",
        "webex.com", "whereby.com", "discord.gg", "slack.com",
    ]

    /// 여러 후보 문자열에서 첫 회의 링크를 찾는다.
    public static func extract(from candidates: [String?]) -> URL? {
        for candidate in candidates.compactMap({ $0 }) {
            if let url = extract(from: candidate) { return url }
        }
        return nil
    }

    public static func extract(from text: String) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: "https?://[^\\s<>\"']+") else { return nil }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            guard let raw = match.substring(at: 0, in: text) else { continue }
            let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,)]>"))
            guard let url = URL(string: trimmed), let host = url.host?.lowercased() else { continue }
            if hosts.contains(where: { host.contains($0) }) { return url }
        }
        return nil
    }
}
