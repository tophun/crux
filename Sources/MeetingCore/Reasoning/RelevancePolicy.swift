import Foundation

/// 사담 제거 정책(§9).
///
/// 판정 기준은 하나다.
/// "이 발언을 제거했을 때, 회의에 참석하지 않은 사람이 결정·액션·배경·리스크를 정확히 이해할 수 있는가?"
///
/// 모델 판정만 믿지 않고 규칙 신호와 합친다. 두 판정이 충돌하면 **보존 쪽으로 기울인다**.
/// 중요한 맥락을 지우는 실수가 사담을 남기는 실수보다 비싸다(§16).
public struct RelevancePolicy: Sendable {
    public init() {}

    // MARK: - 신호 사전

    /// 강한 업무 신호. 하나라도 있으면 사담으로 버리지 않는다.
    /// 의사결정·담당·일정·리스크·비용처럼 회의록의 핵심을 이루는 표현만 넣는다.
    static let strongWorkSignals: [String] = [
        // 의사결정
        "결정", "확정", "정했", "정하기로", "합의", "승인", "반대", "이견", "결론", "동의하",
        // 일정·산출물
        "일정", "마감", "데드라인", "기한", "출시", "릴리즈", "배포", "런칭", "오픈", "연기", "미루",
        // 담당·업무
        "담당", "맡", "책임", "할당", "공유", "요청", "작업", "구현", "수정", "테스트", "qa",
        "리뷰", "스펙", "설계", "문서", "체크리스트", "회귀",
        // 리스크
        "리스크", "위험", "이슈", "장애", "버그", "블로커", "지연", "실패", "오류", "우려", "문제",
        "의존", "제약", "한계",
        // 사업·수치
        "비용", "예산", "매출", "지표", "전환율", "고객", "계약", "가격", "채용", "인원",
        "서버", "성능", "용량", "트래픽", "사용률", "퍼센트",
        // 미해결
        "미정", "미확정", "확인 필요", "정해지지", "결정 못",
    ]

    /// 약한 업무 신호. 시간·수량 표현처럼 그 자체로는 회의록 가치를 보장하지 않는다.
    /// 사담 신호와 함께 나오면 사담으로 본다("다음 주 금요일에 회식" 같은 경우).
    static let weakWorkSignals: [String] = [
        "다음 주", "이번 주", "다음주", "이번주", "내일", "모레", "오늘", "월말", "분기", "이번 달",
        "월요일", "화요일", "수요일", "목요일", "금요일", "토요일", "일요일",
        "확인", "논의", "검토", "진행", "처리", "정리",
    ]

    /// 사담 신호. 강한 업무 신호가 없을 때만 제외 판단에 쓴다.
    static let chatterSignals: [String] = [
        // 인사·안부
        "안녕하세요", "안녕하십니까", "반갑습니다", "오랜만", "오랜만이", "잘 지내", "고생 많",
        "수고하셨", "수고하세요",
        // 회의 전후 대기
        "들리세요", "들리시나요", "소리 잘", "마이크", "화면 공유", "접속", "들어오셨", "기다리",
        "잠시만", "카메라",
        // 날씨·교통·식사
        "날씨", "더워", "추워", "비가", "눈이", "장마", "미세먼지",
        "교통", "지하철", "버스", "막혔", "주차", "늦었습니다", "늦어서",
        "점심", "저녁", "아침 먹", "커피", "식사", "맛집", "배달", "회식", "순대국", "고기",
        // 개인사·취미
        "주말에", "휴가 가", "여행", "가족", "아이가", "애기", "강아지", "고양이",
        "드라마", "영화 봤", "게임", "야구", "축구", "골프", "운동", "재미있었",
        // 감탄·맞장구
        "ㅋㅋ", "ㅎㅎ", "하하", "허허", "그러니까요", "그렇죠", "대박", "헐",
    ]

    /// 단순 맞장구로만 이루어진 짧은 발언
    static let fillerOnly: Set<String> = [
        "네", "네네", "예", "예예", "응", "음", "아", "오", "어", "그렇죠", "맞아요", "맞습니다",
        "알겠습니다", "알겠어요", "좋아요", "좋습니다", "감사합니다", "고맙습니다", "수고하셨습니다",
        "ㅋㅋ", "ㅎㅎ", "하하", "그러니까요", "그러네요", "아 네", "아네", "오케이", "ok",
        "네좋습니다", "네알겠습니다",
    ]

    // MARK: - 규칙 판정

    public struct Heuristic: Hashable, Sendable {
        public var label: RelevanceLabel
        public var hasWorkSignal: Bool
        public var hasChatterSignal: Bool
        public var isPureFiller: Bool
        public var reasons: [String]
    }

    public func heuristic(for segment: TranscriptSegment) -> Heuristic {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = Self.normalize(text)

        let matchedStrong = Self.strongWorkSignals.filter { normalized.contains(Self.normalize($0)) }
        let matchedWeak = Self.weakWorkSignals.filter { normalized.contains(Self.normalize($0)) }
        let matchedChatter = Self.chatterSignals.filter { normalized.contains(Self.normalize($0)) }
        let hasNumber = text.rangeOfCharacter(from: .decimalDigits) != nil
        let isFiller = Self.fillerOnly.contains(normalized) || (normalized.count <= 3 && matchedStrong.isEmpty)

        var reasons: [String] = []
        if !matchedStrong.isEmpty { reasons.append("업무 신호: \(matchedStrong.prefix(3).joined(separator: ","))") }
        if !matchedWeak.isEmpty { reasons.append("시간·수량 표현: \(matchedWeak.prefix(2).joined(separator: ","))") }
        if !matchedChatter.isEmpty { reasons.append("사담 신호: \(matchedChatter.prefix(3).joined(separator: ","))") }
        if hasNumber { reasons.append("수치 포함") }

        let hasStrong = !matchedStrong.isEmpty
        let hasChatter = !matchedChatter.isEmpty

        let label: RelevanceLabel
        if isFiller {
            label = .exclude
            reasons.append("단순 맞장구")
        } else if hasStrong, hasChatter {
            // 사담과 업무 맥락이 섞인 경우 — 개인 사유는 버리고 업무 의미만 남기도록 요약한다.
            label = .condense
        } else if hasStrong {
            label = .keep
        } else if hasChatter {
            // 시간·수량 표현만 있는 사담("다음 주 금요일에 회식")은 회의록에 넣지 않는다.
            label = .exclude
        } else if !matchedWeak.isEmpty || hasNumber {
            label = .keep
        } else {
            // 판단할 신호가 없으면 최소한으로 보존한다.
            label = .uncertain
        }

        return Heuristic(
            label: label,
            hasWorkSignal: hasStrong,
            hasChatterSignal: hasChatter,
            isPureFiller: isFiller,
            reasons: reasons
        )
    }

    /// 모델 판정과 규칙 판정을 합친다.
    /// - 규칙에 업무 신호가 있으면 EXCLUDE로 내리지 않는다 (중요 맥락 보존 우선).
    /// - 모델이 KEEP이라 해도 순수 사담이면 제외한다 (사담 제거 목표 달성).
    public func merge(
        modelLabel: RelevanceLabel?,
        heuristic: Heuristic,
        segment: TranscriptSegment
    ) -> RelevanceDecision {
        guard let modelLabel else {
            return RelevanceDecision(
                segmentId: segment.id,
                label: heuristic.label,
                reason: heuristic.reasons.isEmpty ? "규칙 판정" : heuristic.reasons.joined(separator: "; ")
            )
        }

        // 모델이 버리려 하지만 업무 신호가 있으면 요약 보존으로 올린다.
        if modelLabel == .exclude, heuristic.hasWorkSignal, !heuristic.isPureFiller {
            return RelevanceDecision(
                segmentId: segment.id,
                label: .condense,
                reason: "모델 EXCLUDE이지만 업무 신호가 있어 보존: " + heuristic.reasons.joined(separator: "; ")
            )
        }

        // 모델이 남기려 하지만 순수 사담이면 제외한다.
        if modelLabel != .exclude, heuristic.isPureFiller {
            return RelevanceDecision(
                segmentId: segment.id,
                label: .exclude,
                reason: "단순 맞장구"
            )
        }
        if modelLabel != .exclude, heuristic.hasChatterSignal, !heuristic.hasWorkSignal {
            return RelevanceDecision(
                segmentId: segment.id,
                label: .exclude,
                reason: "업무 신호 없는 사담: " + heuristic.reasons.joined(separator: "; ")
            )
        }

        return RelevanceDecision(segmentId: segment.id, label: modelLabel, reason: nil)
    }

    /// 회의록 생성 입력으로 넘길 세그먼트만 남긴다.
    public func includedSegments(
        _ segments: [TranscriptSegment],
        decisions: [RelevanceDecision]
    ) -> [TranscriptSegment] {
        let excluded = Set(decisions.filter { $0.label == .exclude }.map(\.segmentId))
        return segments.filter { !excluded.contains($0.id) }
    }

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\t", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }
}
