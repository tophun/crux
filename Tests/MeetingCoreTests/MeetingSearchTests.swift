import Foundation
@testable import MeetingCore
import Testing

@Suite("회의 로컬 검색")
struct MeetingSearchTests {
    func document(
        title: String = "결제 모듈 배포 회의",
        notes: [String] = ["배포일 확정. 체크리스트는 따로 공유한다."],
        transcript: [String] = [
            "안녕하세요. 날씨가 좋네요.",
            "결제 모듈 배포는 3월 12일 수요일로 확정합니다."
        ],
        decisions: [String] = ["배포를 3월 12일로 확정"],
        actions: [String] = ["체크리스트 공유"]
    ) -> MeetingSearch.Document {
        MeetingSearch.Document(
            title: title,
            notes: notes,
            transcript: transcript,
            decisions: decisions,
            actions: actions
        )
    }

    @Test("빈 질의와 공백만 있는 질의는 맞춘 문장이 없다")
    func emptyQueryHasNoHit() {
        #expect(MeetingSearch.firstHit(query: "", in: document()) == nil)
        #expect(MeetingSearch.firstHit(query: "   ", in: document()) == nil)
        #expect(MeetingSearch.normalizedQuery(nil) == nil)
        #expect(MeetingSearch.normalizedQuery(" \n") == nil)
    }

    @Test("전사문 질의는 해당 문장을 돌려준다")
    func transcriptSentence() {
        let hit = MeetingSearch.firstHit(query: "3월 12일", in: document())
        #expect(hit?.field == .transcript)
        #expect(hit?.sentence == "결제 모듈 배포는 3월 12일 수요일로 확정합니다.")
    }

    @Test("같은 구절이 여러 필드에 있으면 전사문을 먼저 고른다")
    func prefersTranscriptOverDecision() {
        let hit = MeetingSearch.firstHit(query: "3월 12일", in: document())
        #expect(hit?.field == .transcript)
    }

    @Test("제목만 맞으면 제목을 문장으로 보여 준다")
    func titleHit() {
        let hit = MeetingSearch.firstHit(query: "채용", in: document(title: "채용 계획 회의"))
        #expect(hit?.field == .title)
        #expect(hit?.sentence == "채용 계획 회의")
    }

    @Test("액션 질의는 액션 문장을 돌려준다")
    func actionHit() {
        let hit = MeetingSearch.firstHit(query: "체크리스트", in: document(transcript: ["안녕하세요."]))
        #expect(hit?.field == .action)
        #expect(hit?.sentence == "체크리스트 공유")
    }

    @Test("결정 질의는 결정 문장을 돌려준다")
    func decisionHit() {
        let hit = MeetingSearch.firstHit(
            query: "배포를 3월 12일로",
            in: document(transcript: ["다른 이야기입니다."])
        )
        #expect(hit?.field == .decision)
        #expect(hit?.sentence == "배포를 3월 12일로 확정")
    }

    @Test("회의록 요약에서 맞춘 문장을 잘라 낸다")
    func notesSentence() {
        let hit = MeetingSearch.firstHit(
            query: "체크리스트는",
            in: document(transcript: ["다른 이야기입니다."], actions: ["배포 공지"])
        )
        #expect(hit?.field == .notes)
        #expect(hit?.sentence == "체크리스트는 따로 공유한다.")
    }

    @Test("대소문자를 가리지 않는다")
    func caseInsensitive() {
        let hit = MeetingSearch.firstHit(
            query: "checklist",
            in: document(title: "Sprint", notes: [], transcript: ["Please share the Checklist today."], decisions: [], actions: [])
        )
        #expect(hit?.field == .transcript)
        #expect(hit?.sentence == "Please share the Checklist today.")
    }

    @Test("맞지 않으면 nil이다")
    func noMatch() {
        #expect(MeetingSearch.firstHit(query: "없는단어", in: document()) == nil)
    }

    @Test("필드 표시 이름은 상세 배너에 쓴다")
    func fieldDisplayNames() {
        #expect(MeetingSearch.Field.title.displayName == "제목")
        #expect(MeetingSearch.Field.notes.displayName == "회의록")
        #expect(MeetingSearch.Field.transcript.displayName == "전사문")
        #expect(MeetingSearch.Field.decision.displayName == "결정사항")
        #expect(MeetingSearch.Field.action.displayName == "액션")
    }
}
