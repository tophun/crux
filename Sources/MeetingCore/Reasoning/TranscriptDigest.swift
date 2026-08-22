import Foundation

/// 회의록 생성 입력으로 쓸 전사 요약. 사담(EXCLUDE)은 빠지고, CONDENSE는 짧게 줄인다(§9).
public struct TranscriptDigestBuilder: Sendable {
    /// 최종 종합 단계에 넣을 최대 문자 수. 컨텍스트 폭발을 막는다(§12).
    public var maxCharacters: Int
    /// CONDENSE 구간을 남길 최대 길이
    public var condensedLimit: Int

    public init(maxCharacters: Int = 4000, condensedLimit: Int = 60) {
        self.maxCharacters = maxCharacters
        self.condensedLimit = condensedLimit
    }

    public func build(
        segments: [TranscriptSegment],
        decisions: [RelevanceDecision]
    ) -> String {
        let labels = Dictionary(decisions.map { ($0.segmentId, $0.label) }, uniquingKeysWith: { first, _ in first })
        var lines: [String] = []
        var total = 0

        for segment in segments.sorted(by: { $0.startTime < $1.startTime }) {
            let label = labels[segment.id] ?? .uncertain
            guard label.isIncludedInNote else { continue }
            var text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            if label == .condense, text.count > condensedLimit {
                text = String(text.prefix(condensedLimit)) + "…"
            }
            let speaker = segment.speakerId.map { "\($0): " } ?? ""
            let line = "[\(TimeFormat.stamp(segment.startTime))] \(speaker)\(text)"
            if total + line.count > maxCharacters {
                lines.append("(이후 구간은 길이 제한으로 생략됨 — 후보 목록에 이미 반영되어 있음)")
                break
            }
            lines.append(line)
            total += line.count
        }

        return lines.joined(separator: "\n")
    }
}
