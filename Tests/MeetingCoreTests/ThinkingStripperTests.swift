import Foundation
import Testing
@testable import MeetingCore

@Suite("내부 사고 제거")
struct ThinkingStripperTests {
    @Test("사고 블록은 결과에서 완전히 제거된다")
    func removesThinkingBlock() {
        let raw = "<think>이건 결정인지 제안인지 애매하다</think>\n{\"verdict\": \"confirm\"}"
        let result = ThinkingStripper.strip(raw)
        #expect(result.containedThinking)
        #expect(!result.thinkingTruncated)
        #expect(result.visibleText == "{\"verdict\": \"confirm\"}")
        #expect(!result.visibleText.contains("애매"))
    }

    @Test("사고가 잘려도 태그 앞 내용만 남기고 사고 내용은 노출하지 않는다")
    func handlesTruncatedThinking() {
        let raw = "결과를 정리하면\n<think>토큰이 부족해서 여기서 끊김"
        let result = ThinkingStripper.strip(raw)
        #expect(result.containedThinking)
        #expect(result.thinkingTruncated)
        #expect(result.visibleText == "결과를 정리하면")
        #expect(!result.visibleText.contains("토큰이 부족"))
    }

    @Test("사고 블록이 없으면 원문을 그대로 둔다")
    func passesThroughWithoutThinking() {
        let raw = "{\"title\": \"회의\"}"
        let result = ThinkingStripper.strip(raw)
        #expect(!result.containedThinking)
        #expect(result.visibleText == raw)
    }

    @Test("여러 사고 블록이 있으면 마지막 블록 이후를 사용한다")
    func usesLastBlock() {
        let raw = "<think>첫 번째</think>중간<think>두 번째</think>{\"ok\": true}"
        let result = ThinkingStripper.strip(raw)
        #expect(result.visibleText.contains("{\"ok\": true}"))
        #expect(!result.visibleText.contains("첫 번째"))
        #expect(!result.visibleText.contains("두 번째"))
    }
}
