import Foundation

/// 모델의 내부 사고(`<think>...</think>`)를 제거한다.
/// 사고 내용은 사용자에게 노출하지 않고 저장하지도 않는다(§7).
public enum ThinkingStripper {
    public struct Result: Hashable, Sendable {
        /// 사고 블록을 제거한 사용자/파서용 텍스트
        public var visibleText: String
        /// 사고 블록이 존재했는지
        public var containedThinking: Bool
        /// 사고 블록이 닫히지 않은 채 생성이 끝났는지 (토큰 한계 등)
        public var thinkingTruncated: Bool
    }

    private static let openTag = "<think>"
    private static let closeTag = "</think>"

    public static func strip(_ raw: String) -> Result {
        guard raw.contains(openTag) || raw.contains(closeTag) else {
            return Result(visibleText: raw, containedThinking: false, thinkingTruncated: false)
        }

        // 닫는 태그가 있으면 마지막 닫는 태그 이후만 사용한다.
        if let lastClose = raw.range(of: closeTag, options: .backwards) {
            let tail = String(raw[lastClose.upperBound...])
            // 닫는 태그 앞의 텍스트 중 열린 태그 앞부분은 사고 이전 서두이므로 함께 살린다.
            let headRaw = String(raw[raw.startIndex..<lastClose.lowerBound])
            let head: String
            if let firstOpen = headRaw.range(of: openTag) {
                head = String(headRaw[headRaw.startIndex..<firstOpen.lowerBound])
            } else {
                head = ""
            }
            let merged = (head + "\n" + tail).trimmingCharacters(in: .whitespacesAndNewlines)
            return Result(visibleText: merged, containedThinking: true, thinkingTruncated: false)
        }

        // 열린 태그만 있으면 사고가 잘린 것으로 보고 태그 앞부분만 남긴다.
        if let firstOpen = raw.range(of: openTag) {
            let head = String(raw[raw.startIndex..<firstOpen.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Result(visibleText: head, containedThinking: true, thinkingTruncated: true)
        }

        return Result(visibleText: raw, containedThinking: false, thinkingTruncated: false)
    }
}
