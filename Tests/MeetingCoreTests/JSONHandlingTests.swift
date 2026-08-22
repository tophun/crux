import Foundation
import Testing
@testable import MeetingCore

@Suite("LLM JSON 처리")
struct JSONHandlingTests {
    @Test("코드펜스와 설명이 붙어도 JSON을 추출한다")
    func extractsFromCodeFence() throws {
        let raw = """
        아래와 같이 정리했습니다.
        ```json
        {"title": "배포 회의", "summary": "요약"}
        ```
        """
        let extraction = try JSONExtractor.extract(from: raw)
        #expect(extraction.value["title"].stringValue == "배포 회의")
    }

    @Test("trailing comma와 스마트 쿼트를 복구한다")
    func repairsCommonMistakes() throws {
        let raw = "{\u{201C}title\u{201D}: \u{201C}회의\u{201D}, \"items\": [1, 2, ],}"
        let extraction = try JSONExtractor.extract(from: raw)
        #expect(extraction.repaired)
        #expect(extraction.value["title"].stringValue == "회의")
        #expect(extraction.value["items"].arrayValue.count == 2)
    }

    @Test("토큰 한계로 잘린 JSON을 닫아서 복구한다")
    func closesTruncatedJSON() throws {
        let raw = "{\"decisions\": [{\"content\": \"배포일 확정\", \"confidence\": 0.9}, {\"content\": \"미완"
        let extraction = try JSONExtractor.extract(from: raw)
        #expect(extraction.repaired)
        #expect(extraction.value["decisions"].arrayValue.count >= 1)
        #expect(extraction.value["decisions"].arrayValue[0]["content"].stringValue == "배포일 확정")
    }

    @Test("주석이 섞여도 복구한다")
    func removesComments() throws {
        let raw = """
        {
          // 결정사항
          "title": "회의"
        }
        """
        let extraction = try JSONExtractor.extract(from: raw)
        #expect(extraction.value["title"].stringValue == "회의")
    }

    @Test("JSON이 전혀 없으면 오류를 던진다 — 파이프라인이 복구 재요청을 할 수 있어야 한다")
    func throwsWhenNoJSON() {
        #expect(throws: StructuredOutputError.self) {
            _ = try JSONExtractor.extract(from: "죄송합니다. 회의록을 만들 수 없습니다.")
        }
    }

    @Test("문자열 안의 중괄호는 구조 판정에 영향을 주지 않는다")
    func ignoresBracesInStrings() throws {
        let raw = "{\"summary\": \"코드 {a: 1} 를 논의함\"}"
        let extraction = try JSONExtractor.extract(from: raw)
        #expect(extraction.value["summary"].stringValue == "코드 {a: 1} 를 논의함")
    }

    @Test("숫자·불리언·키 표기 흔들림을 흡수한다")
    func lenientAccess() throws {
        let value = try JSONValue.parse("""
        {"action_items": {"task": "배포", "confidence": "85%", "assignee": "null"}}
        """)
        let items = value["actionItems"].arrayValue
        #expect(items.count == 1)
        #expect(items[0]["task"].stringValue == "배포")
        #expect(items[0]["confidence"].confidenceValue == 0.85)
        #expect(items[0]["assignee"].stringValue == nil)
    }

    @Test("신뢰도는 0과 1 사이로 정리된다")
    func clampsConfidence() throws {
        let value = try JSONValue.parse("{\"a\": 95, \"b\": -3, \"c\": 0.42}")
        #expect(value["a"].confidenceValue == 0.95)
        #expect(value["b"].confidenceValue == 0)
        #expect(value["c"].confidenceValue == 0.42)
    }
}
