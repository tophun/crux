import Foundation

/// 1차 추출 단위. 1시간 회의 전사문을 한 번에 모델에 넣지 않기 위한 5~10분 창(§12).
public struct TranscriptWindow: Hashable, Sendable {
    public var index: Int
    /// 이 창에서 추출·판정 대상이 되는 세그먼트
    public var segments: [TranscriptSegment]
    /// 직전 창의 마지막 몇 개 세그먼트. 맥락 참고용이며 추출 대상은 아니다.
    public var contextSegments: [TranscriptSegment]

    public init(index: Int, segments: [TranscriptSegment], contextSegments: [TranscriptSegment] = []) {
        self.index = index
        self.segments = segments
        self.contextSegments = contextSegments
    }

    public var startTime: TimeInterval {
        segments.first?.startTime ?? 0
    }

    public var endTime: TimeInterval {
        segments.last?.endTime ?? 0
    }

    public var duration: TimeInterval {
        max(0, endTime - startTime)
    }

    public func segment(forShortId shortId: String) -> TranscriptSegment? {
        let normalized = shortId.trimmingCharacters(in: .whitespaces).uppercased()
        return (segments + contextSegments).first { $0.shortId.uppercased() == normalized }
    }

    /// 프롬프트에 넣는 전사문. 짧은 식별자(S12)와 타임스탬프를 함께 준다.
    public func promptTranscript() -> String {
        var lines: [String] = []
        if !contextSegments.isEmpty {
            lines.append("[이전 맥락 — 추출 대상 아님]")
            lines += contextSegments.map { line(for: $0) }
            lines.append("[이번 구간]")
        }
        lines += segments.map { line(for: $0) }
        return lines.joined(separator: "\n")
    }

    private func line(for segment: TranscriptSegment) -> String {
        let speaker = segment.speakerId.map { "\($0): " } ?? ""
        let confidence = segment.confidence.map { String(format: " (인식신뢰도 %.2f)", $0) } ?? ""
        return "\(segment.shortId) [\(TimeFormat.stamp(segment.startTime))-\(TimeFormat.stamp(segment.endTime))] \(speaker)\(segment.text)\(confidence)"
    }
}

public enum TimeFormat {
    /// mm:ss 또는 h:mm:ss
    public static func stamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}

/// 전사문을 창으로 나눈다. 시간과 문자 수 두 가지 예산을 모두 지킨다.
public struct TranscriptChunker: Sendable {
    public struct Configuration: Sendable {
        /// 목표 창 길이(초). 기본 8분.
        public var targetDuration: TimeInterval
        /// 최대 창 길이(초). 기본 10분.
        public var maxDuration: TimeInterval
        /// 최대 문자 수. 한국어는 대략 1자≈1토큰으로 보고 컨텍스트를 보수적으로 잡는다.
        public var maxCharacters: Int
        /// 다음 창에 넘겨줄 맥락 세그먼트 수
        public var contextSegmentCount: Int

        public init(
            targetDuration: TimeInterval = 480,
            maxDuration: TimeInterval = 600,
            maxCharacters: Int = 3500,
            contextSegmentCount: Int = 2
        ) {
            self.targetDuration = targetDuration
            self.maxDuration = maxDuration
            self.maxCharacters = maxCharacters
            self.contextSegmentCount = contextSegmentCount
        }
    }

    public var configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func windows(for segments: [TranscriptSegment]) -> [TranscriptWindow] {
        let ordered = segments.sorted { ($0.startTime, $0.index) < ($1.startTime, $1.index) }
        guard !ordered.isEmpty else { return [] }

        var windows: [TranscriptWindow] = []
        var current: [TranscriptSegment] = []
        var currentCharacters = 0

        func flush() {
            guard !current.isEmpty else { return }
            let context = Array(
                (windows.last?.segments ?? []).suffix(configuration.contextSegmentCount)
            )
            windows.append(
                TranscriptWindow(index: windows.count, segments: current, contextSegments: context)
            )
            current = []
            currentCharacters = 0
        }

        for segment in ordered {
            let projectedCharacters = currentCharacters + segment.text.count
            let projectedDuration = (segment.endTime - (current.first?.startTime ?? segment.startTime))

            let exceedsCharacters = !current.isEmpty && projectedCharacters > configuration.maxCharacters
            let exceedsDuration = !current.isEmpty && projectedDuration > configuration.maxDuration
            let reachedTarget = !current.isEmpty
                && projectedDuration >= configuration.targetDuration
                && projectedCharacters >= configuration.maxCharacters / 2

            if exceedsCharacters || exceedsDuration || reachedTarget {
                flush()
            }

            current.append(segment)
            currentCharacters += segment.text.count
        }
        flush()

        return windows
    }
}
