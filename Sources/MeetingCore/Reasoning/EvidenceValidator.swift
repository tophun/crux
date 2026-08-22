import Foundation

/// 근거 검증. 모델이 만들어낸 인용을 회의록에 남기지 않기 위한 마지막 방어선(§2, §17).
///
/// 검증 규칙
///   1. 인용문이 지목된 세그먼트 원문에 실제로 있으면 통과
///   2. 다른 세그먼트에 있으면 그 세그먼트로 교정
///   3. 어디에도 없으면 근거를 버리고 이유를 기록 (항목은 신뢰도 하향)
public struct EvidenceValidator: Sendable {
    public struct Outcome: Sendable {
        public var evidence: [Evidence]
        public var rejected: [String]
        public var retargeted: Int
    }

    /// 인용문 일치 판정에 필요한 최소 길이. 너무 짧은 인용은 우연히 일치할 수 있다.
    public var minimumQuoteLength: Int
    /// 인용이 원문과 같다고 볼 겹침 비율 (전사 정규화 차이 흡수)
    public var minimumOverlap: Double
    /// 인용을 구간 원문으로 대체해도 된다고 볼 최소 겹침 비율.
    /// 모델이 원문을 조금 바꿔 인용한 경우 근거 자체를 잃지 않도록 한다.
    public var substitutionOverlap: Double

    public init(
        minimumQuoteLength: Int = 4,
        minimumOverlap: Double = 0.75,
        substitutionOverlap: Double = 0.3
    ) {
        self.minimumQuoteLength = minimumQuoteLength
        self.minimumOverlap = minimumOverlap
        self.substitutionOverlap = substitutionOverlap
    }

    /// 짧은 식별자(S12) 기반 근거를 실제 세그먼트로 확정한다.
    public func resolve(
        shortId: String?,
        quote: String?,
        in window: TranscriptWindow
    ) -> (evidence: Evidence?, reason: String?) {
        let candidates = window.segments + window.contextSegments
        let trimmedQuote = (quote ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. 지목된 세그먼트 확인
        if let shortId, let segment = window.segment(forShortId: shortId) {
            if trimmedQuote.isEmpty {
                // 인용이 없으면 세그먼트 원문을 그대로 근거로 쓴다 (원문에 있는 문장이므로 안전).
                return (makeEvidence(from: segment, quote: segment.text), nil)
            }
            if matches(quote: trimmedQuote, in: segment.text) {
                return (makeEvidence(from: segment, quote: trimmedQuote), nil)
            }
        }

        // 2. 인용문으로 다른 세그먼트 탐색
        if !trimmedQuote.isEmpty, trimmedQuote.count >= minimumQuoteLength {
            if let matched = candidates.first(where: { matches(quote: trimmedQuote, in: $0.text) }) {
                return (
                    makeEvidence(from: matched, quote: trimmedQuote),
                    "근거 세그먼트를 \(matched.shortId)로 교정"
                )
            }
        }

        // 3. 모델이 원문을 바꿔 인용한 경우 — 구간은 살리고 인용만 원문으로 대체한다.
        //    근거를 통째로 버리면 항목이 근거 부족으로 폐기되는 연쇄가 생긴다.
        if let shortId, let segment = window.segment(forShortId: shortId),
           TextSimilarity.overlap(trimmedQuote, segment.text) >= substitutionOverlap {
            return (
                makeEvidence(from: segment, quote: segment.text),
                "인용이 원문과 달라 \(segment.shortId) 원문으로 대체"
            )
        }

        // 4. 지목된 구간이 틀렸을 수 있으니 내용이 가장 가까운 구간을 찾아본다.
        if !trimmedQuote.isEmpty, trimmedQuote.count >= minimumQuoteLength {
            let scored = candidates
                .map { ($0, TextSimilarity.overlap(trimmedQuote, $0.text)) }
                .filter { $0.1 >= 0.45 }
                .max { $0.1 < $1.1 }
            if let (segment, _) = scored {
                return (
                    makeEvidence(from: segment, quote: segment.text),
                    "인용과 가장 가까운 \(segment.shortId) 원문으로 대체"
                )
            }
        }

        // 5. 실패
        let identifier = shortId ?? "(없음)"
        return (nil, "원문에서 확인되지 않은 근거 제거 (segment=\(identifier), quote=\(String(trimmedQuote.prefix(30))))")
    }

    /// 이미 확정된 근거들이 전체 전사문과 일치하는지 다시 확인한다.
    public func validate(
        evidence: [Evidence],
        segments: [TranscriptSegment]
    ) -> Outcome {
        var accepted: [Evidence] = []
        var rejected: [String] = []
        var retargeted = 0
        let byId = Dictionary(uniqueKeysWithValues: segments.map { ($0.id.uuidString, $0) })

        for item in evidence {
            if let segment = byId[item.segmentId], matches(quote: item.quote, in: segment.text) {
                accepted.append(
                    Evidence(
                        segmentId: item.segmentId,
                        startTime: segment.startTime,
                        endTime: segment.endTime,
                        quote: item.quote
                    )
                )
                continue
            }
            if item.quote.count >= minimumQuoteLength,
               let matched = segments.first(where: { matches(quote: item.quote, in: $0.text) }) {
                accepted.append(makeEvidence(from: matched, quote: item.quote))
                retargeted += 1
                continue
            }
            rejected.append("원문 불일치 근거 제거: \(String(item.quote.prefix(30)))")
        }

        return Outcome(evidence: dedupe(accepted), rejected: rejected, retargeted: retargeted)
    }

    // MARK: - 내부

    func makeEvidence(from segment: TranscriptSegment, quote: String) -> Evidence {
        Evidence(
            segmentId: segment.id.uuidString,
            startTime: segment.startTime,
            endTime: segment.endTime,
            quote: quote
        )
    }

    /// 공백·문장부호 차이를 무시한 부분 일치. 완전 일치가 아니면 겹침 비율로 판단한다.
    func matches(quote: String, in text: String) -> Bool {
        let normalizedQuote = Self.normalize(quote)
        let normalizedText = Self.normalize(text)
        guard !normalizedQuote.isEmpty, !normalizedText.isEmpty else { return false }
        if normalizedText.contains(normalizedQuote) { return true }
        if normalizedQuote.contains(normalizedText), normalizedText.count >= minimumQuoteLength { return true }
        guard normalizedQuote.count >= minimumQuoteLength else { return false }
        // 인용은 보통 구간의 일부이므로 겹침 계수로 본다. jaccard는 길이 차이에 지나치게 민감하다.
        return TextSimilarity.overlap(normalizedQuote, normalizedText) >= minimumOverlap
    }

    func dedupe(_ evidence: [Evidence]) -> [Evidence] {
        var seen: Set<String> = []
        var result: [Evidence] = []
        for item in evidence {
            let key = item.segmentId + "|" + Self.normalize(item.quote)
            if seen.insert(key).inserted { result.append(item) }
        }
        return result.sorted { $0.startTime < $1.startTime }
    }

    static func normalize(_ text: String) -> String {
        let allowed = text.lowercased().filter { $0.isLetter || $0.isNumber }
        return allowed
    }
}
