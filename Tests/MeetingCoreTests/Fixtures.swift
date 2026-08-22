import Foundation
@testable import MeetingCore

enum Fixtures {
    static let meetingId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    static func segment(
        _ index: Int,
        _ text: String,
        start: TimeInterval? = nil,
        confidence: Double? = 0.9,
        speaker: String? = nil
    ) -> TranscriptSegment {
        let startTime = start ?? TimeInterval(index) * 10
        return TranscriptSegment(
            meetingId: meetingId,
            index: index,
            startTime: startTime,
            endTime: startTime + 9,
            speakerId: speaker,
            text: text,
            confidence: confidence
        )
    }

    /// 결정·액션·사담·모호 표현이 섞인 짧은 회의
    static var meetingSegments: [TranscriptSegment] {
        [
            segment(0, "안녕하세요. 오늘 비가 많이 와서 늦었습니다."),
            segment(1, "점심에 순대국 먹었는데 짰어요."),
            segment(2, "결제 모듈 배포는 3월 12일 수요일로 확정합니다."),
            segment(3, "홍길동 님이 배포 체크리스트를 다음 주 월요일까지 공유해 주세요."),
            segment(4, "네."),
            segment(5, "서버 시피유 사용률이 피크에 85퍼센트까지 올라가서 위험합니다."),
            segment(6, "증설 비용은 일단 보류하고 다음 주에 다시 논의하겠습니다."),
            segment(7, "가격 정책은 아직 정해지지 않았습니다. 사업팀 확인이 필요합니다."),
            segment(8, "다음 주 금요일에 회식하려고 하는데 다들 가능하신가요."),
        ]
    }

    static func window(_ segments: [TranscriptSegment], index: Int = 0) -> TranscriptWindow {
        TranscriptWindow(index: index, segments: segments)
    }

    static func fact(
        kind: MeetingFact.Kind,
        content: String,
        assignee: String? = nil,
        dueDate: String? = nil,
        dueDateNote: String? = nil,
        decisionKind: DecisionKind? = nil,
        evidence: [Evidence] = [],
        confidence: Double = 0.9,
        windowIndex: Int = 0,
        notes: [String] = []
    ) -> MeetingFact {
        MeetingFact(
            meetingId: meetingId,
            windowIndex: windowIndex,
            kind: kind,
            content: content,
            assignee: assignee,
            dueDate: dueDate,
            dueDateNote: dueDateNote,
            decisionKind: decisionKind,
            evidence: evidence,
            confidence: confidence,
            ambiguityNotes: notes
        )
    }

    static func evidence(for segment: TranscriptSegment, quote: String? = nil) -> Evidence {
        Evidence(
            segmentId: segment.id.uuidString,
            startTime: segment.startTime,
            endTime: segment.endTime,
            quote: quote ?? segment.text
        )
    }
}
