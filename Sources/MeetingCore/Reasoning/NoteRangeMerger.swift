import Foundation

/// 선택 구간에 해당하는 회의록 항목만 갈아 끼운다. 바깥 항목과 근거 시각은 유지한다.
public enum NoteRangeMerger {
    public static func evidenceOverlaps(_ evidence: [Evidence], range: TimeRange) -> Bool {
        evidence.contains { range.overlaps($0) }
    }

    /// 제목·요약·사용자 문서는 그대로 두고, 근거가 선택 구간과 겹치는 항목만 `incoming`으로 교체한다.
    public static func merge(existing: MeetingNote, incoming: MeetingNote, range: TimeRange) -> MeetingNote {
        var merged = existing
        merged.decisions = replace(
            existing.decisions,
            with: incoming.decisions,
            range: range,
            overlaps: { evidenceOverlaps($0.evidence, range: $1) }
        )
        merged.actionItems = replace(
            existing.actionItems,
            with: incoming.actionItems,
            range: range,
            overlaps: { evidenceOverlaps($0.evidence, range: $1) }
        )
        merged.openQuestions = replace(
            existing.openQuestions,
            with: incoming.openQuestions,
            range: range,
            overlaps: { evidenceOverlaps($0.evidence, range: $1) }
        )
        merged.risks = replace(
            existing.risks,
            with: incoming.risks,
            range: range,
            overlaps: { evidenceOverlaps($0.evidence, range: $1) }
        )
        merged.topics = replace(
            existing.topics,
            with: incoming.topics,
            range: range,
            overlaps: topicOverlaps
        )
        return merged
    }

    private static func topicOverlaps(_ topic: Topic, range: TimeRange) -> Bool {
        guard let start = topic.startTime, let end = topic.endTime else {
            return false
        }
        return range.overlaps(start: start, end: end)
    }

    private static func replace<Item>(
        _ existing: [Item],
        with incoming: [Item],
        range: TimeRange,
        overlaps: (Item, TimeRange) -> Bool
    ) -> [Item] {
        existing.filter { !overlaps($0, range) } + incoming
    }
}
