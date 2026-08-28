import Foundation

/// 회의 오디오·전사문의 시간 구간. 시작은 포함, 끝은 제외에 가깝게 겹침을 판정한다.
public struct TimeRange: Hashable, Sendable, Codable {
    public var start: TimeInterval
    public var end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval {
        max(0, end - start)
    }

    /// 시작이 끝보다 앞이고, 음수가 아니며, 유한한 길이일 때만 다시 전사에 쓸 수 있다.
    public var isValid: Bool {
        start.isFinite && end.isFinite && start >= 0 && end > start
    }

    public func overlaps(start otherStart: TimeInterval, end otherEnd: TimeInterval) -> Bool {
        start < otherEnd && end > otherStart
    }

    public func overlaps(_ other: TimeRange) -> Bool {
        overlaps(start: other.start, end: other.end)
    }

    public func overlaps(_ segment: TranscriptSegment) -> Bool {
        overlaps(start: segment.startTime, end: segment.endTime)
    }

    public func overlaps(_ evidence: Evidence) -> Bool {
        overlaps(start: evidence.startTime, end: evidence.endTime)
    }

    /// 오디오 길이 안으로 잘라 낸다. 잘린 뒤에도 비어 있으면 `isValid`가 false다.
    public func clamped(toDuration duration: TimeInterval) -> TimeRange {
        TimeRange(start: max(0, start), end: min(max(0, duration), end))
    }
}
