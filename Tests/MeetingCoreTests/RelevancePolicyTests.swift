import Foundation
import Testing
@testable import MeetingCore

@Suite("불필요한 사담 제거")
struct RelevancePolicyTests {
    let policy = RelevancePolicy()

    @Test("인사·날씨·식사 대화는 제외로 분류된다")
    func excludesSmallTalk() {
        let cases = [
            "안녕하세요. 오늘 비가 많이 와서 늦었습니다.",
            "점심에 순대국 먹었는데 짰어요.",
            "주말에 야구 봤는데 재미있었어요.",
            "다들 들리시나요. 마이크 확인 좀 하겠습니다.",
        ]
        for text in cases {
            let heuristic = policy.heuristic(for: Fixtures.segment(0, text))
            #expect(heuristic.label == .exclude, "사담으로 분류되지 않음: \(text)")
        }
    }

    @Test("단순 맞장구는 제외된다")
    func excludesFiller() {
        for text in ["네", "맞아요", "알겠습니다", "ㅋㅋ"] {
            let heuristic = policy.heuristic(for: Fixtures.segment(0, text))
            #expect(heuristic.isPureFiller)
            #expect(heuristic.label == .exclude)
        }
    }

    @Test("결정·일정·리스크·수치는 유지된다")
    func keepsWorkContent() {
        let cases = [
            "결제 모듈 배포는 3월 12일 수요일로 확정합니다.",
            "서버 시피유 사용률이 85퍼센트까지 올라가서 위험합니다.",
            "홍길동 님이 체크리스트를 다음 주 월요일까지 공유해 주세요.",
        ]
        for text in cases {
            let heuristic = policy.heuristic(for: Fixtures.segment(0, text))
            #expect(heuristic.label == .keep, "유지되지 않음: \(text)")
            #expect(heuristic.hasWorkSignal)
        }
    }

    @Test("사담과 업무가 섞이면 요약 보존한다 — 개인 사유는 버리고 업무 의미만 남긴다")
    func condensesMixedContent() {
        let segment = Fixtures.segment(
            0,
            "주말에 아이가 아파서 일정이 좀 꼬였는데, 아무튼 이번 배포는 다음 주 수요일쯤 가능할 것 같습니다."
        )
        let heuristic = policy.heuristic(for: segment)
        #expect(heuristic.label == .condense)
        #expect(heuristic.hasWorkSignal)
        #expect(heuristic.hasChatterSignal)
    }

    @Test("모델이 버리려 해도 업무 신호가 있으면 보존한다 — 중요 맥락 삭제 방지가 우선")
    func upgradesModelExcludeWhenWorkSignalPresent() {
        let segment = Fixtures.segment(0, "증설 비용은 월 300만 원 추가로 들어갑니다.")
        let decision = policy.merge(
            modelLabel: .exclude,
            heuristic: policy.heuristic(for: segment),
            segment: segment
        )
        #expect(decision.label == .condense)
        #expect(decision.reason?.contains("업무 신호") == true)
    }

    @Test("모델이 남기려 해도 순수 사담이면 제외한다")
    func downgradesModelKeepForPureChatter() {
        let segment = Fixtures.segment(0, "오늘 날씨가 참 좋네요.")
        let decision = policy.merge(
            modelLabel: .keep,
            heuristic: policy.heuristic(for: segment),
            segment: segment
        )
        #expect(decision.label == .exclude)
    }

    @Test("모델 판정이 없으면 규칙 판정을 사용한다")
    func fallsBackToHeuristic() {
        let segment = Fixtures.segment(0, "배포일은 3월 12일로 확정합니다.")
        let decision = policy.merge(modelLabel: nil, heuristic: policy.heuristic(for: segment), segment: segment)
        #expect(decision.label == .keep)
    }

    @Test("제외된 구간은 회의록 입력에서 빠지지만 전사문에는 남는다")
    func filtersOnlyNoteInput() {
        let segments = Fixtures.meetingSegments
        let decisions = segments.map {
            policy.merge(modelLabel: nil, heuristic: policy.heuristic(for: $0), segment: $0)
        }
        let included = policy.includedSegments(segments, decisions: decisions)
        #expect(included.count < segments.count)
        #expect(included.contains { $0.text.contains("3월 12일 수요일로 확정") })
        #expect(!included.contains { $0.text.contains("순대국") })
        // 원본 전사문 배열은 변하지 않는다.
        #expect(segments.count == 9)
    }
}
