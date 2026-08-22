import Foundation
@testable import MeetingCore

/// 스크립트로 응답하는 가짜 LLM. 실제 모델 없이 파이프라인 전체를 검증한다.
actor FakeLanguageModel: LocalLanguageModel {
    struct Call: Sendable {
        var mode: ReasoningMode
        var prompt: String
        var kind: Kind

        enum Kind: String, Sendable {
            case extraction, review, finalNote, repair, unknown
        }
    }

    private(set) var calls: [Call] = []
    private(set) var loadCount = 0
    private(set) var unloadCount = 0
    private let responder: @Sendable (Call, Int) -> String

    init(responder: @escaping @Sendable (Call, Int) -> String) {
        self.responder = responder
    }

    func generate(prompt: String, mode: ReasoningMode, maxTokens _: Int) async throws -> String {
        let kind: Call.Kind = if prompt.contains("형식만 고쳐서") {
            .repair
        } else if prompt.contains("segmentRelevance") {
            .extraction
        } else if prompt.contains("재검토가 필요한 이유") {
            .review
        } else if prompt.contains("evidenceIndex") {
            .finalNote
        } else {
            .unknown
        }
        let call = Call(mode: mode, prompt: prompt, kind: kind)
        let index = calls.count(where: { $0.kind == kind })
        calls.append(call)
        return responder(call, index)
    }

    func load() async throws { loadCount += 1 }
    func unload() async { unloadCount += 1 }

    func callLog() -> [Call] { calls }
}

enum FakeResponses {
    /// 픽스처 회의에 맞는 정상 1차 추출 응답
    static let extraction = """
    {
      "topics": [{"title": "배포 일정", "summary": "3월 배포와 서버 용량"}],
      "decisions": [
        {"content": "결제 모듈 배포를 3월 12일 수요일로 확정", "kind": "decided", "confidence": 0.92,
         "evidence": [{"segment": "S2", "quote": "3월 12일 수요일로 확정합니다"}]},
        {"content": "증설 비용은 일단 보류하고 다음 주에 다시 논의", "kind": "decided", "confidence": 0.55,
         "ambiguity": ["보류 표현이 있어 확정 여부가 불분명"],
         "evidence": [{"segment": "S6", "quote": "일단 보류하고 다음 주에 다시 논의하겠습니다"}]}
      ],
      "actionItems": [
        {"task": "배포 체크리스트를 작성해 공유", "assignee": "홍길동", "dueDate": null,
         "dueDateNote": "다음 주 월요일", "confidence": 0.85,
         "evidence": [{"segment": "S3", "quote": "배포 체크리스트를 다음 주 월요일까지 공유해 주세요"}]}
      ],
      "risks": [
        {"content": "결제 서버 CPU 사용률이 피크 85%로 배포 후 한계 우려", "severity": "high", "confidence": 0.8,
         "evidence": [{"segment": "S5", "quote": "85퍼센트까지 올라가서 위험합니다"}]}
      ],
      "openQuestions": [
        {"question": "가격 정책이 정해지지 않아 사업팀 확인이 필요", "confidence": 0.7,
         "evidence": [{"segment": "S7", "quote": "아직 정해지지 않았습니다"}]}
      ],
      "segmentRelevance": [
        {"segment": "S0", "label": "EXCLUDE"},
        {"segment": "S1", "label": "EXCLUDE"},
        {"segment": "S2", "label": "KEEP"},
        {"segment": "S3", "label": "KEEP"},
        {"segment": "S4", "label": "EXCLUDE"},
        {"segment": "S5", "label": "KEEP"},
        {"segment": "S6", "label": "KEEP"},
        {"segment": "S7", "label": "KEEP"},
        {"segment": "S8", "label": "EXCLUDE"}
      ]
    }
    """

    /// 재검토 대상에 맞는 응답을 돌려준다 (실제 모델처럼 항목별로 다르게 답한다).
    ///
    /// 프롬프트 전체가 아니라 "후보 항목"의 내용 줄만 보고 판단한다.
    /// 프롬프트에는 전사문과 관련 후보가 함께 들어 있어 전체 문자열로 판단하면 엉뚱한 응답을 준다.
    static func review(for prompt: String) -> String {
        let target = prompt
            .components(separatedBy: "\n")
            .first { $0.hasPrefix("        - 내용: ") || $0.trimmingCharacters(in: .whitespaces).hasPrefix("- 내용:") }?
            .trimmingCharacters(in: .whitespaces) ?? ""

        if target.contains("체크리스트") {
            return """
            <think>담당자가 원문에 있고 마감 표현은 모호하다.</think>
            {"verdict": "confirm", "content": "배포 체크리스트를 작성해 공유", "assignee": "홍길동",
             "dueDate": null, "dueDateNote": "다음 주 월요일", "confidence": 0.85,
             "evidence": [{"segment": "S3", "quote": "배포 체크리스트를 다음 주 월요일까지 공유해 주세요"}]}
            """
        }
        if target.contains("보류") {
            return review
        }
        return "{\"verdict\": \"confirm\", \"confidence\": 0.8}"
    }

    /// 사고 모드 재검토 응답 — 보류 항목을 제안으로 낮춘다.
    static let review = """
    <think>보류라고 했으니 결정이 아니다. 제안으로 낮춘다.</think>
    {"verdict": "revise", "content": "증설 비용 집행은 보류하고 다음 주 재논의", "kind": "proposed",
     "assignee": null, "dueDate": null, "confidence": 0.6,
     "evidence": [{"segment": "S6", "quote": "일단 보류하고 다음 주에 다시 논의하겠습니다"}]}
    """

    static let finalNote = """
    {
      "title": "결제 모듈 배포 회의",
      "summary": "결제 모듈 배포일을 3월 12일 수요일로 확정했다. 배포 체크리스트는 홍길동이 다음 주 월요일까지 공유한다. 서버 CPU 사용률이 피크 85%로 배포 후 용량 한계가 우려된다. 증설 비용 집행과 가격 정책은 아직 결정되지 않았다.",
      "decisions": [
        {"content": "결제 모듈 배포를 3월 12일 수요일로 확정", "kind": "decided", "evidenceIndex": 1},
        {"content": "증설 비용 집행은 보류하고 다음 주 재논의", "kind": "proposed", "evidenceIndex": 2}
      ],
      "actionItems": [
        {"task": "배포 체크리스트를 작성해 공유", "assignee": "홍길동", "dueDate": null, "status": "confirmed", "evidenceIndex": 1}
      ],
      "openQuestions": [{"question": "가격 정책이 정해지지 않아 사업팀 확인이 필요", "evidenceIndex": 1}],
      "risks": [{"content": "결제 서버 CPU 사용률이 피크 85%로 배포 후 한계 우려", "severity": "high", "evidenceIndex": 1}],
      "topics": [{"title": "배포 일정", "summary": "3월 배포와 서버 용량"}]
    }
    """
}
