import Foundation
@testable import MeetingCore
import Testing

@Suite("구간 재전사 패치")
struct TranscriptRangePatcherTests {
    let meetingId = UUID()

    func segment(
        id: UUID = UUID(),
        index: Int,
        start: TimeInterval,
        end: TimeInterval,
        text: String
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            meetingId: meetingId,
            index: index,
            startTime: start,
            endTime: end,
            text: text
        )
    }

    @Test("한 구간만 바꿔도 다른 구간의 id·텍스트·시각은 그대로다")
    func patchKeepsOutsideRanges() {
        let first = segment(index: 0, start: 0, end: 8, text: "첫 구간")
        let middle = segment(index: 1, start: 8, end: 16, text: "틀린 구간")
        let last = segment(index: 2, start: 16, end: 24, text: "마지막 구간")
        let replacement = [
            segment(index: 0, start: 8, end: 16, text: "고친 구간")
        ]

        let result = TranscriptRangePatcher.patch(
            existing: [first, middle, last],
            range: TimeRange(start: 8, end: 16),
            replacement: replacement,
            meetingId: meetingId
        )

        #expect(result.segments.count == 3)
        #expect(result.keptIds == [first.id, last.id])
        #expect(result.removedIds == [middle.id])

        #expect(result.segments[0].id == first.id)
        #expect(result.segments[0].text == "첫 구간")
        #expect(result.segments[0].startTime == 0)
        #expect(result.segments[0].endTime == 8)
        #expect(result.segments[0].index == 0)

        #expect(result.segments[1].text == "고친 구간")
        #expect(result.segments[1].id != middle.id)
        #expect(result.segments[1].startTime == 8)
        #expect(result.segments[1].endTime == 16)
        #expect(result.segments[1].index == 1)

        #expect(result.segments[2].id == last.id)
        #expect(result.segments[2].text == "마지막 구간")
        #expect(result.segments[2].startTime == 16)
        #expect(result.segments[2].endTime == 24)
        #expect(result.segments[2].index == 2)
    }

    @Test("클립 기준 시각을 회의 시각으로 옮긴다")
    func shiftsClipRelativeTimestamps() {
        let clip = [segment(index: 0, start: 0, end: 8, text: "클립")]
        let shifted = TranscriptRangePatcher.shifted(clip, by: 16)
        #expect(shifted[0].startTime == 16)
        #expect(shifted[0].endTime == 24)
        #expect(shifted[0].text == "클립")
    }

    @Test("선택한 두 구간 사이의 구간을 모두 고른다")
    func spanningIncludesEndpoints() {
        let segments = [
            segment(index: 0, start: 0, end: 8, text: "A"),
            segment(index: 1, start: 8, end: 16, text: "B"),
            segment(index: 2, start: 16, end: 24, text: "C")
        ]
        let selected = TranscriptRangePatcher.spanning(
            from: segments[0].id,
            to: segments[2].id,
            in: segments
        )
        #expect(selected.map(\.text) == ["A", "B", "C"])
        #expect(TranscriptRangePatcher.covering(selected) == TimeRange(start: 0, end: 24))
    }
}

@Suite("구간 회의록 항목 병합")
struct NoteRangeMergerTests {
    let meetingId = UUID()

    func evidence(start: TimeInterval, end: TimeInterval, quote: String) -> Evidence {
        Evidence(segmentId: UUID().uuidString, startTime: start, endTime: end, quote: quote)
    }

    @Test("한 구간만 다시 뽑아도 다른 구간의 근거 시각은 유지한다")
    func keepsOutsideEvidenceTimestamps() {
        let outside = evidence(start: 2, end: 6, quote: "바깥 근거")
        let inside = evidence(start: 10, end: 14, quote: "안쪽 근거")
        var existing = MeetingNote(meetingId: meetingId, title: "원래 제목", summary: "원래 요약")
        existing.customDocument = "사용자가 고친 문서"
        existing.decisions = [
            Decision(content: "바깥 결정", kind: .decided, evidence: [outside], confidence: 0.9),
            Decision(content: "안쪽 결정", kind: .decided, evidence: [inside], confidence: 0.8)
        ]
        existing.actionItems = [
            ActionItem(task: "바깥 액션", evidence: [outside], confidence: 0.9)
        ]

        let incomingEvidence = evidence(start: 11, end: 15, quote: "새 근거")
        var incoming = MeetingNote(meetingId: meetingId, title: "새 제목", summary: "새 요약")
        incoming.decisions = [
            Decision(content: "고친 결정", kind: .decided, evidence: [incomingEvidence], confidence: 0.95)
        ]

        let merged = NoteRangeMerger.merge(
            existing: existing,
            incoming: incoming,
            range: TimeRange(start: 8, end: 16)
        )

        #expect(merged.title == "원래 제목")
        #expect(merged.summary == "원래 요약")
        #expect(merged.customDocument == "사용자가 고친 문서")
        #expect(merged.decisions.count == 2)
        #expect(merged.decisions[0].content == "바깥 결정")
        #expect(merged.decisions[0].evidence[0].startTime == 2)
        #expect(merged.decisions[0].evidence[0].endTime == 6)
        #expect(merged.decisions[0].evidence[0].quote == "바깥 근거")
        #expect(merged.decisions[1].content == "고친 결정")
        #expect(merged.actionItems.count == 1)
        #expect(merged.actionItems[0].task == "바깥 액션")
        #expect(merged.actionItems[0].evidence[0].startTime == 2)
    }
}
