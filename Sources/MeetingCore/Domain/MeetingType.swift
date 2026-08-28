import Foundation

/// 회의 유형. 프롬프트와 회의록 섹션 강조만 바꾸고, 사담 제거·근거 검증 규칙은 공통이다.
///
/// 고르지 않으면 `general` — 지금과 같은 구성이다.
public enum MeetingType: String, Codable, Sendable, CaseIterable, Hashable {
    case general
    case scrum
    case oneOnOne
    case review

    public var displayName: String {
        switch self {
        case .general: "일반"
        case .scrum: "스크럼"
        case .oneOnOne: "1:1"
        case .review: "리뷰"
        }
    }

    /// 메뉴에 쓰는 이름. 기본 유형임을 분명히 적는다.
    public var menuTitle: String {
        self == .general ? "\(displayName) (기본)" : displayName
    }

    /// CLI·설정 문자열을 유형으로 읽는다. 모르는 값은 nil.
    public static func parse(_ value: String) -> MeetingType? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "general", "일반": .general
        case "scrum", "스크럼": .scrum
        case "oneonone", "one-on-one", "one_on_one", "1:1", "1-1": .oneOnOne
        case "review", "리뷰": .review
        default: MeetingType(rawValue: value)
        }
    }

    /// 1차 추출 프롬프트에 붙는 강조. 일반은 nil이라 지금 프롬프트와 같다.
    public var extractionEmphasis: String? {
        switch self {
        case .general:
            nil
        case .scrum:
            """
            이 구간은 스크럼이다. 완료한 일(한 일)과 막힌 점·장애(이슈)를 빠뜨리지 말고 추출하라.
            한 일은 topics와 actionItems로, 이슈는 risks로 남긴다.
            """
        case .oneOnOne:
            """
            이 구간은 1:1이다. 서로 약속한 일(누가 무엇을 하기로 했는지)을 빠뜨리지 말고 추출하라.
            약속은 actionItems로 남긴다.
            """
        case .review:
            """
            이 구간은 리뷰다. 확정된 결정과 리스크를 빠뜨리지 말고 추출하라.
            결정은 decisions로, 리스크는 risks로 남긴다.
            """
        }
    }

    /// 최종 회의록 프롬프트에 붙는 강조. 일반은 nil이라 지금 프롬프트와 같다.
    public var finalNoteEmphasis: String? {
        switch self {
        case .general:
            nil
        case .scrum:
            "8. 이 회의는 스크럼이다. summary에는 한 일과 이슈를 먼저 드러내고, 완료된 작업은 topics에, 장애는 risks에 모은다."
        case .oneOnOne:
            "8. 이 회의는 1:1이다. summary에는 서로 한 약속을 먼저 드러내고, 약속은 actionItems에 모은다."
        case .review:
            "8. 이 회의는 리뷰다. summary에는 결정과 리스크를 먼저 드러내고, 확정된 판단은 decisions에, 장애 요인은 risks에 모은다."
        }
    }
}
