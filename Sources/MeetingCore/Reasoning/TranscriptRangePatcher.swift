import Foundation

/// 선택 구간의 새 전사 결과만 끼워 넣고, 나머지 구간 식별자와 시각은 그대로 둔다.
public enum TranscriptRangePatcher {
    public struct Result: Sendable {
        public var segments: [TranscriptSegment]
        /// 선택 구간과 겹쳐 빠진 기존 구간.
        public var removedIds: Set<UUID>
        /// 손대지 않은 기존 구간. 회의록 근거가 가리키는 식별자를 유지한다.
        public var keptIds: Set<UUID>
    }

    /// 클립 기준(0초부터) 시각을 회의 시각으로 옮긴다.
    public static func shifted(_ segments: [TranscriptSegment], by delta: TimeInterval) -> [TranscriptSegment] {
        segments.map { segment in
            var updated = segment
            updated.startTime += delta
            updated.endTime += delta
            return updated
        }
    }

    /// `range`와 겹치는 구간을 `replacement`로 바꾸고, 바깥 구간은 id·텍스트·시각을 유지한 채 다시 번호를 매긴다.
    public static func patch(
        existing: [TranscriptSegment],
        range: TimeRange,
        replacement: [TranscriptSegment],
        meetingId: UUID
    ) -> Result {
        let kept = existing.filter { !range.overlaps($0) }
        let removedIds = Set(existing.map(\.id)).subtracting(kept.map(\.id))
        let incoming = replacement.map { segment -> TranscriptSegment in
            var updated = segment
            updated.meetingId = meetingId
            return updated
        }
        let merged = (kept + incoming).sorted { lhs, rhs in
            if lhs.startTime != rhs.startTime {
                return lhs.startTime < rhs.startTime
            }
            return lhs.endTime < rhs.endTime
        }
        let reindexed = merged.enumerated().map { offset, segment -> TranscriptSegment in
            var updated = segment
            updated.index = offset
            return updated
        }
        return Result(
            segments: reindexed,
            removedIds: removedIds,
            keptIds: Set(kept.map(\.id))
        )
    }

    /// 선택된 두 구간 사이(양 끝 포함)에 있는 구간.
    public static func spanning(
        from firstId: UUID,
        to secondId: UUID,
        in segments: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        guard let first = segments.first(where: { $0.id == firstId }),
              let second = segments.first(where: { $0.id == secondId })
        else {
            return []
        }
        let low = min(first.startTime, second.startTime)
        let high = max(first.endTime, second.endTime)
        return segments.filter { $0.startTime >= low && $0.endTime <= high }
    }

    /// 구간들의 시작~끝. 비어 있으면 nil.
    public static func covering(_ segments: [TranscriptSegment]) -> TimeRange? {
        guard let start = segments.map(\.startTime).min(),
              let end = segments.map(\.endTime).max(),
              end > start
        else {
            return nil
        }
        return TimeRange(start: start, end: end)
    }
}
