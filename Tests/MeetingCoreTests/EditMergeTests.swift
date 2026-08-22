import Foundation
import Testing

@testable import MeetingCore

/// 산출물 편집이 근거를 잃지 않는지 확인한다.
///
/// 화면 코드(`mergeEdits`)와 같은 규칙을 여기서 검증한다. 중간 항목을 지웠을 때
/// 근거가 한 칸씩 밀려 엉뚱한 항목에 붙는 것이 가장 위험한 실수다.
@Suite("회의록 편집 병합")
struct EditMergeTests {
    private struct Edit {
        var text: String
        var originalIndex: Int?
    }

    private func merge(_ edits: [Edit], into originals: [Decision]) -> [Decision] {
        edits.map { edit in
            if let index = edit.originalIndex, originals.indices.contains(index) {
                var updated = originals[index]
                updated.content = edit.text
                return updated
            }
            return Decision(content: edit.text, kind: .decided)
        }
    }

    private func sample() -> [Decision] {
        (0..<3).map { index in
            Decision(
                content: "결정 \(index)",
                kind: .decided,
                evidence: [Evidence(segmentId: "seg-\(index)", startTime: Double(index), endTime: Double(index) + 1, quote: "인용 \(index)")]
            )
        }
    }

    @Test("가운데 항목을 지워도 남은 항목이 자기 근거를 지킨다")
    func keepsEvidenceAfterDeletion() {
        let originals = sample()
        let merged = merge([Edit(text: "결정 0", originalIndex: 0), Edit(text: "결정 2", originalIndex: 2)], into: originals)
        #expect(merged.count == 2)
        #expect(merged[0].evidence.first?.quote == "인용 0")
        #expect(merged[1].evidence.first?.quote == "인용 2")
    }

    @Test("본문을 고쳐도 근거와 확정 여부는 그대로다")
    func keepsEvidenceAfterRewrite() {
        let originals = sample()
        let merged = merge([Edit(text: "다시 쓴 결정", originalIndex: 1)], into: originals)
        #expect(merged[0].content == "다시 쓴 결정")
        #expect(merged[0].evidence.first?.quote == "인용 1")
        #expect(merged[0].id == originals[1].id)
    }

    @Test("새로 추가한 항목은 근거 없이 만들어진다 — 없는 근거를 붙이지 않는다")
    func newItemHasNoEvidence() {
        let merged = merge([Edit(text: "사용자가 추가", originalIndex: nil)], into: sample())
        #expect(merged[0].evidence.isEmpty)
    }

    @Test("원본 범위를 벗어난 위치는 새 항목으로 본다")
    func outOfRangeIndexIsNew() {
        let merged = merge([Edit(text: "이상한 위치", originalIndex: 99)], into: sample())
        #expect(merged[0].evidence.isEmpty)
        #expect(merged[0].content == "이상한 위치")
    }
}

@Suite("결정사항 표시 규칙")
struct DecisionDisplayTests {
    @Test("확정된 결정에는 표시를 붙이지 않는다")
    func decidedHasNoMarker() {
        let decision = Decision(content: "목요일 배포", kind: .decided)
        #expect(DecisionDisplay.text(for: decision) == "목요일 배포")
    }

    @Test("제안은 구분 표시를 붙였다가 저장할 때 그대로 되돌린다")
    func proposalRoundTrip() {
        let decision = Decision(content: "성능 개선 검토", kind: .proposed)
        let shown = DecisionDisplay.text(for: decision)
        #expect(shown.hasPrefix("["))
        // 손대지 않고 저장해도 본문이 그대로여야 한다.
        #expect(DecisionDisplay.stripped(shown) == "성능 개선 검토")
    }

    @Test("사용자가 직접 쓴 대괄호는 자르지 않는다")
    func keepsUserBrackets() {
        #expect(DecisionDisplay.stripped("[백엔드] 배포 확정") == "[백엔드] 배포 확정")
        #expect(DecisionDisplay.stripped("[TODO]") == "[TODO]")
    }
}
