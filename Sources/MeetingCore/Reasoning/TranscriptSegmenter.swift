import Foundation

/// 너무 긴 전사 구간을 문장 단위로 나눈다.
///
/// 음성 인식 결과의 구간 길이는 VAD와 디코딩 옵션에 따라 크게 달라진다.
/// 한 구간에 여러 주제가 들어가면 근거 타임스탬프가 뭉뚝해지고, 사담과 업무 발언이 같은 구간에 섞여
/// 사담 분류도 어려워진다. 그래서 저장 전에 문장 경계로 다시 나눈다.
///
/// 나뉜 구간의 시각은 원래 구간 안에서 글자 수 비율로 배분한 근사값이다.
public struct TranscriptSegmenter: Sendable {
    /// 이 길이를 넘는 구간만 분할한다.
    public var maxCharacters: Int
    /// 분할 후 이 길이보다 짧은 조각은 앞 조각에 붙인다.
    public var minCharacters: Int

    public init(maxCharacters: Int = 90, minCharacters: Int = 12) {
        self.maxCharacters = maxCharacters
        self.minCharacters = minCharacters
    }

    public func split(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        for segment in segments {
            let pieces = sentences(in: segment.text)
            guard segment.text.count > maxCharacters, pieces.count > 1 else {
                result.append(reindexed(segment, index: result.count))
                continue
            }

            let totalCharacters = pieces.reduce(0) { $0 + $1.count }
            let span = max(0, segment.endTime - segment.startTime)
            var offset = 0
            for piece in pieces {
                let start = segment.startTime + span * Double(offset) / Double(max(totalCharacters, 1))
                offset += piece.count
                let end = segment.startTime + span * Double(offset) / Double(max(totalCharacters, 1))
                result.append(
                    TranscriptSegment(
                        meetingId: segment.meetingId,
                        index: result.count,
                        startTime: start,
                        endTime: end,
                        speakerId: segment.speakerId,
                        text: piece,
                        confidence: segment.confidence,
                        sourceTrack: segment.sourceTrack
                    )
                )
            }
        }
        return result
    }

    /// 한국어 종결부호와 종결어미를 기준으로 문장을 나눈다.
    func sentences(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var pieces: [String] = []
        var current = ""
        let characters = Array(trimmed)

        for (index, character) in characters.enumerated() {
            current.append(character)
            let isTerminator = character == "." || character == "?" || character == "!"
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            // 숫자 사이의 마침표(3.5 같은 값)는 문장 끝으로 보지 않는다.
            let isDecimalPoint = character == "."
                && index > 0
                && characters[index - 1].isNumber
                && (next?.isNumber ?? false)
            if isTerminator, !isDecimalPoint {
                pieces.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            pieces.append(current.trimmingCharacters(in: .whitespaces))
        }

        // 종결부호가 없어 한 덩어리로 남으면 종결어미로 한 번 더 시도한다.
        if pieces.count == 1, pieces[0].count > maxCharacters {
            pieces = splitByEndings(pieces[0])
        }

        return merge(pieces)
    }

    /// "…습니다 …입니다 …하세요"처럼 종결어미 뒤에서 나눈다.
    func splitByEndings(_ text: String) -> [String] {
        let endings = ["습니다", "합니다", "입니다", "하세요", "하겠습니다", "됩니다", "있습니다", "없습니다"]
        var pieces: [String] = []
        var remainder = Substring(text)

        while !remainder.isEmpty {
            var cut: String.Index?
            for ending in endings {
                if let range = remainder.range(of: ending) {
                    let candidate = range.upperBound
                    if cut == nil || candidate < cut! { cut = candidate }
                }
            }
            guard let cut, cut < remainder.endIndex else {
                pieces.append(String(remainder).trimmingCharacters(in: .whitespaces))
                break
            }
            pieces.append(String(remainder[remainder.startIndex ..< cut]).trimmingCharacters(in: .whitespaces))
            remainder = remainder[cut...]
        }
        return pieces.filter { !$0.isEmpty }
    }

    /// 너무 짧은 조각은 앞 조각에 붙인다.
    func merge(_ pieces: [String]) -> [String] {
        var result: [String] = []
        for piece in pieces {
            if let last = result.last, piece.count < minCharacters {
                result[result.count - 1] = last + " " + piece
            } else {
                result.append(piece)
            }
        }
        return result
    }

    private func reindexed(_ segment: TranscriptSegment, index: Int) -> TranscriptSegment {
        var updated = segment
        updated.index = index
        return updated
    }
}
