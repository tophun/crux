import Foundation

/// 외부로 나가는 본문에 근거·전사 원문·내부 ID가 섞이지 않았는지 검사한다(요구사항 7).
///
/// 프롬프트 약속이 아니라 게시 직전 실행되는 게이트다. 위반이 있으면 게시를 중단한다.
public enum PublishRedaction {
    public struct Violation: Hashable, Sendable {
        public var kind: Kind
        public var detail: String

        public enum Kind: String, Sendable {
            case uuid
            case evidenceQuote
            case timestamp
            case internalKey
        }
    }

    static let uuidPattern = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
    static let internalKeys = ["segmentId", "transcript", "evidence", "startTime", "endTime"]

    /// - Parameters:
    ///   - text: 실제로 전송할 본문 (Confluence storage body, Jira 필드 JSON 등)
    ///   - evidence: 로컬 근거 파일. 이 안의 인용문과 타임스탬프가 본문에 있으면 위반이다.
    public static func audit(text: String, evidence: EvidenceBundle) -> [Violation] {
        var violations: [Violation] = []

        if let regex = try? NSRegularExpression(pattern: uuidPattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let found = match.substring(at: 0, in: text) {
            violations.append(Violation(kind: .uuid, detail: found))
        }

        for key in internalKeys where text.contains("\"\(key)\"") {
            violations.append(Violation(kind: .internalKey, detail: key))
        }

        for item in evidence.items {
            let normalizedContent = normalize(item.content)
            for entry in item.evidence {
                // 근거 인용문 — 짧은 인용은 우연히 겹칠 수 있으므로 길이 기준을 둔다.
                let quote = entry.quote.trimmingCharacters(in: .whitespacesAndNewlines)
                guard quote.count >= 12 else { continue }
                // 회의록 항목 본문 자체가 원문 문장과 같은 경우가 있다(모델이 발언을 그대로 옮긴 경우).
                // 사용자가 검토·승인한 항목 본문에 이미 포함된 문장은 "전사문 유출"이 아니다.
                if normalizedContent.contains(normalize(quote)) {
                    continue
                }
                if text.contains(quote) {
                    violations.append(Violation(kind: .evidenceQuote, detail: String(quote.prefix(30))))
                }
                // 근거 타임스탬프 표기
                for stamp in [TimeFormat.stamp(entry.startTime), TimeFormat.stamp(entry.endTime)]
                    where text.contains(stamp) {
                    violations.append(Violation(kind: .timestamp, detail: stamp))
                }
            }
        }

        return violations
    }

    /// 공백·문장부호 차이를 무시한 비교용 정규화
    static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    public static func describe(_ violations: [Violation]) -> String {
        violations
            .map { "\($0.kind.rawValue): \($0.detail)" }
            .joined(separator: ", ")
    }
}

public enum PublishError: Error, LocalizedError, Sendable {
    case redactionFailed([PublishRedaction.Violation])
    case notApproved
    case missingCredentials(String)
    case api(status: Int, message: String)
    case invalidResponse(String)
    case spaceNotFound(String)
    case nothingToPublish
    case missingDestination
    case missingSlackCredentials(String)
    case slackAPI(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case let .redactionFailed(violations):
            "게시 본문에 내보내면 안 되는 내용이 있어 중단했습니다: \(PublishRedaction.describe(violations))"
        case .notApproved:
            "사용자가 승인하지 않은 내용은 전송하지 않습니다."
        case let .missingCredentials(message):
            "Atlassian 인증 정보가 없습니다: \(message)"
        case let .api(status, message):
            "Atlassian API 오류(\(status)): \(message)"
        case let .invalidResponse(message):
            "응답을 해석할 수 없습니다: \(message)"
        case let .spaceNotFound(key):
            "Confluence Space를 찾을 수 없습니다: \(key)"
        case .nothingToPublish:
            "게시할 항목이 없습니다."
        case .missingDestination:
            "Slack 채널 또는 DM을 지정해야 합니다."
        case let .missingSlackCredentials(message):
            "Slack 인증 정보가 없습니다: \(message)"
        case let .slackAPI(status, message):
            "Slack API 오류(\(status)): \(message)"
        }
    }
}
