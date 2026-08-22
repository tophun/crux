import Foundation
import Testing
@testable import MeetingCore

extension Fixtures {
    /// 게시 테스트용 회의록 — 근거·담당자·기한이 모두 들어 있다.
    static func publishableNote() -> MeetingNote {
        let segments = meetingSegments
        var note = MeetingNote(
            meetingId: meetingId,
            title: "결제 모듈 배포 회의",
            summary: "배포일을 3월 12일로 확정했고 체크리스트는 다음 주 월요일까지 공유한다."
        )
        note.decisions = [
            Decision(
                content: "결제 모듈 배포를 3월 12일 수요일로 확정",
                kind: .decided,
                evidence: [evidence(for: segments[2], quote: "결제 모듈 배포는 3월 12일 수요일로 확정합니다.")],
                confidence: 0.95
            ),
            Decision(
                content: "증설 비용 집행은 보류하고 다음 주 재논의",
                kind: .proposed,
                evidence: [evidence(for: segments[6], quote: "일단 보류하고 다음 주에 다시 논의하겠습니다.")],
                confidence: 0.6
            ),
        ]
        note.actionItems = [
            ActionItem(
                task: "배포 체크리스트 작성 및 공유",
                assignee: "홍길동",
                dueDate: "3월 10일",
                status: .confirmed,
                evidence: [evidence(for: segments[3], quote: "홍길동 님이 배포 체크리스트를 다음 주 월요일까지 공유해 주세요.")],
                confidence: 0.9
            ),
            ActionItem(
                task: "회귀 테스트 완료",
                assignee: nil,
                dueDate: nil,
                dueDateNote: "화요일 오전",
                status: .proposed,
                evidence: [evidence(for: segments[5], quote: "서버 시피유 사용률이 피크에 85퍼센트까지 올라가서 위험합니다.")],
                confidence: 0.7
            ),
        ]
        note.risks = [RiskItem(content: "서버 용량 초과 위험", severity: .high)]
        note.openQuestions = [OpenQuestion(question: "가격 정책 미정 — 사업팀 확인 필요")]
        note.topics = [Topic(title: "배포 일정", summary: "3월 배포와 체크리스트")]
        return note
    }

    static func meeting(startedAt: Date = Date(timeIntervalSince1970: 1_772_000_000)) -> Meeting {
        Meeting(
            id: meetingId,
            title: "결제 모듈 배포 회의",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(1800),
            status: .completed,
            storageDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
        )
    }
}

@Suite("근거 파일 분리")
struct EvidenceBundleTests {
    @Test("회의록 항목마다 내부 contentId를 붙인다")
    func assignsContentIds() {
        let bundle = EvidenceBundle.make(from: Fixtures.publishableNote())
        #expect(bundle.items.map(\.contentId) == ["D1", "D2", "A1", "A2", "R1", "Q1"])
        #expect(bundle.item(contentId: "A1")?.content == "배포 체크리스트 작성 및 공유")
        #expect(bundle.item(contentId: "D1")?.evidence.first?.quote.contains("3월 12일") == true)
    }

    @Test("근거 파일 이름은 {meetingId}.evidence.json이다")
    func fileNaming() {
        #expect(EvidenceBundle.fileName(meetingId: Fixtures.meetingId) == "\(Fixtures.meetingId.uuidString).evidence.json")
    }

    @Test("근거 파일은 타임스탬프와 원문을 그대로 보관한다")
    func roundTrip() throws {
        let bundle = EvidenceBundle.make(from: Fixtures.publishableNote())
        let data = try bundle.encoded()
        let restored = try EvidenceBundle.decoded(from: data)
        #expect(restored.items.count == bundle.items.count)
        #expect(restored.item(contentId: "D1")?.evidence.first?.startTime == bundle.item(contentId: "D1")?.evidence.first?.startTime)
        // 근거 파일 안에는 타임스탬프가 있어야 한다 (외부 게시물과 대비).
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("startTime"))
    }
}

@Suite("한국어 기한 해석")
struct KoreanDateParserTests {
    let reference = Date(timeIntervalSince1970: 1_772_000_000)  // 2026-02-25 기준

    @Test("ISO 날짜를 그대로 해석한다")
    func parsesISO() {
        #expect(KoreanDateParser.jiraDueDate("2026-03-12", reference: reference) == "2026-03-12")
        #expect(KoreanDateParser.jiraDueDate("2026/03/12", reference: reference) == "2026-03-12")
    }

    @Test("월일 표현은 기준 연도를 붙인다")
    func parsesMonthDay() {
        let result = KoreanDateParser.jiraDueDate("3월 12일", reference: reference)
        #expect(result?.hasSuffix("-03-12") == true)
    }

    @Test("상대 표현은 날짜로 확정하지 않는다")
    func rejectsRelativeExpressions() {
        for text in ["다음 주 월요일", "화요일 오전", "추후", "조만간", "다음 달"] {
            #expect(KoreanDateParser.jiraDueDate(text, reference: reference) == nil, "확정하면 안 되는 표현: \(text)")
        }
    }

    @Test("빈 값과 nil은 nil로 처리한다")
    func handlesEmpty() {
        #expect(KoreanDateParser.jiraDueDate(nil, reference: reference) == nil)
        #expect(KoreanDateParser.jiraDueDate("  ", reference: reference) == nil)
    }
}

@Suite("게시 초안 구성")
struct PublishBundleBuilderTests {
    let builder = PublishBundleBuilder()

    func options() -> PublishBundleBuilder.Options {
        PublishBundleBuilder.Options(spaceKey: "TEAM", projectKey: "PROJ")
    }

    @Test("제목·날짜·참석자는 캘린더 정보를 우선 사용한다")
    func prefersCalendarMetadata() {
        let event = Fixtures.event(id: "evt", title: "주간 유저성장 회의", startOffset: 0)
        let bundle = builder.build(
            note: Fixtures.publishableNote(),
            meeting: Fixtures.meeting(),
            event: event,
            options: options()
        )
        #expect(bundle.page.title == "주간 유저성장 회의")
        #expect(bundle.page.attendees == event.attendeeDisplayNames)
        #expect(bundle.page.meetingDate.contains("년"))
    }

    @Test("캘린더 정보가 없으면 참석자를 만들어내지 않는다")
    func doesNotInventAttendees() {
        let bundle = builder.build(
            note: Fixtures.publishableNote(),
            meeting: Fixtures.meeting(),
            event: nil,
            options: options()
        )
        #expect(bundle.page.attendees.isEmpty)
        #expect(bundle.page.title == "결제 모듈 배포 회의")
    }

    @Test("확정된 결정만 결정사항에 넣고 제안은 논의 내용으로 옮긴다")
    func separatesDecisionsFromProposals() {
        let bundle = builder.build(
            note: Fixtures.publishableNote(),
            meeting: Fixtures.meeting(),
            event: nil,
            options: options()
        )
        #expect(bundle.page.decisions == ["결제 모듈 배포를 3월 12일 수요일로 확정"])
        #expect(bundle.page.discussion.contains { $0.topic == "검토 중" && $0.detail.contains("보류") })
    }

    @Test("담당자·기한이 없으면 미확정으로 표기한다")
    func marksUnresolvedFields() {
        let bundle = builder.build(
            note: Fixtures.publishableNote(),
            meeting: Fixtures.meeting(),
            event: nil,
            options: options()
        )
        let second = bundle.page.actionItems[1]
        #expect(second.assignee == UnresolvedMarker.undetermined)
        #expect(second.dueDate.contains(UnresolvedMarker.needsConfirmation))
    }

    @Test("해석 가능한 기한만 Jira duedate로 넣고 나머지는 본문에 남긴다")
    func convertsDueDates() {
        let bundle = builder.build(
            note: Fixtures.publishableNote(),
            meeting: Fixtures.meeting(),
            event: nil,
            options: options()
        )
        #expect(bundle.issues[0].dueDate?.hasSuffix("-03-10") == true)
        #expect(bundle.issues[1].dueDate == nil)
        #expect(bundle.issues[1].detailParagraphs.contains { $0.contains("화요일 오전") })
        #expect(bundle.issues[1].detailParagraphs.contains { $0.contains("담당자가 회의에서 확인되지 않았습니다") })
    }

    @Test("Jira 초안은 기본 Task이고 유형·우선순위를 고를 수 있다")
    func defaultIssueType() {
        let bundle = builder.build(
            note: Fixtures.publishableNote(),
            meeting: Fixtures.meeting(),
            event: nil,
            options: PublishBundleBuilder.Options(
                spaceKey: "TEAM",
                projectKey: "PROJ",
                defaultIssueType: "Story",
                defaultPriority: "High"
            )
        )
        #expect(bundle.issues.allSatisfy { $0.issueTypeName == "Story" })
        #expect(bundle.issues.allSatisfy { $0.priorityName == "High" })
        #expect(JiraIssueDraft.selectableIssueTypes.contains("Bug"))
    }

    @Test("Jira description은 ADF 문서 구조를 만든다")
    func buildsADF() {
        let bundle = builder.build(
            note: Fixtures.publishableNote(),
            meeting: Fixtures.meeting(),
            event: nil,
            options: options()
        )
        let adf = bundle.issues[0].descriptionADF()
        #expect(adf["type"] as? String == "doc")
        #expect(adf["version"] as? Int == 1)
        let content = adf["content"] as? [[String: Any]]
        #expect(content?.isEmpty == false)
        #expect(content?.first?["type"] as? String == "paragraph")
    }

    @Test("Confluence 본문은 날짜와 참석자를 가장 먼저 노출한다")
    func pageOrdering() {
        let event = Fixtures.event(id: "evt", startOffset: 0)
        let bundle = builder.build(
            note: Fixtures.publishableNote(),
            meeting: Fixtures.meeting(),
            event: event,
            options: options()
        )
        let html = bundle.page.storageBody()
        let dateIndex = html.range(of: "날짜")!.lowerBound
        let attendeeIndex = html.range(of: "참석자")!.lowerBound
        let summaryIndex = html.range(of: "회의 요약")!.lowerBound
        let decisionIndex = html.range(of: "주요 결정사항")!.lowerBound
        let actionIndex = html.range(of: "액션 아이템")!.lowerBound
        let discussionIndex = html.range(of: "논의 내용")!.lowerBound
        let riskIndex = html.range(of: "리스크 및 미해결 질문")!.lowerBound

        #expect(dateIndex < attendeeIndex)
        #expect(attendeeIndex < summaryIndex)
        #expect(summaryIndex < decisionIndex)
        #expect(decisionIndex < actionIndex)
        #expect(actionIndex < discussionIndex)
        #expect(discussionIndex < riskIndex)
    }

    @Test("HTML 특수문자를 이스케이프한다")
    func escapesHTML() {
        var note = Fixtures.publishableNote()
        note.summary = "a < b & \"인용\""
        let bundle = builder.build(note: note, meeting: Fixtures.meeting(), event: nil, options: options())
        let html = bundle.page.storageBody()
        #expect(html.contains("&lt;"))
        #expect(html.contains("&amp;"))
        #expect(!html.contains("a < b"))
    }
}

@Suite("게시 검열 게이트")
struct PublishRedactionTests {
    @Test("정상 게시 본문은 위반이 없다")
    func cleanPayloadPasses() {
        let note = Fixtures.publishableNote()
        let evidence = EvidenceBundle.make(from: note)
        let bundle = PublishBundleBuilder().build(
            note: note,
            meeting: Fixtures.meeting(),
            event: nil,
            options: PublishBundleBuilder.Options(spaceKey: "TEAM", projectKey: "PROJ")
        )
        let payload = bundle.page.storageBody()
            + bundle.includedIssues.flatMap(\.detailParagraphs).joined(separator: " ")
        let violations = PublishRedaction.audit(text: payload, evidence: evidence)
        #expect(violations.isEmpty, "\(PublishRedaction.describe(violations))")
    }

    @Test("근거 인용문이 섞이면 게시를 막는다")
    func detectsEvidenceQuote() {
        let note = Fixtures.publishableNote()
        let evidence = EvidenceBundle.make(from: note)
        let quote = note.decisions[0].evidence[0].quote
        let violations = PublishRedaction.audit(text: "<p>\(quote)</p>", evidence: evidence)
        #expect(violations.contains { $0.kind == .evidenceQuote })
    }

    @Test("타임스탬프 표기가 섞이면 게시를 막는다")
    func detectsTimestamp() {
        let note = Fixtures.publishableNote()
        let evidence = EvidenceBundle.make(from: note)
        let stamp = TimeFormat.stamp(note.decisions[0].evidence[0].startTime)
        let violations = PublishRedaction.audit(text: "<p>근거 \(stamp)</p>", evidence: evidence)
        #expect(violations.contains { $0.kind == .timestamp })
    }

    @Test("내부 UUID와 내부 키가 섞이면 게시를 막는다")
    func detectsInternalIdentifiers() {
        let evidence = EvidenceBundle.make(from: Fixtures.publishableNote())
        let withUUID = PublishRedaction.audit(text: "meeting \(UUID().uuidString)", evidence: evidence)
        #expect(withUUID.contains { $0.kind == .uuid })

        let withKey = PublishRedaction.audit(text: "{\"segmentId\": \"S1\"}", evidence: evidence)
        #expect(withKey.contains { $0.kind == .internalKey })
    }
}

@Suite("게시 전 품질 검증")
struct MeetingQualityCheckerTests {
    let checker = MeetingQualityChecker()

    func bundle(for note: MeetingNote) -> PublishBundle {
        PublishBundleBuilder().build(
            note: note,
            meeting: Fixtures.meeting(),
            event: nil,
            options: PublishBundleBuilder.Options(spaceKey: "TEAM", projectKey: "PROJ")
        )
    }

    @Test("정상 회의록은 게시할 수 있고 미확정 항목은 경고로 남는다")
    func allowsPublishWithWarnings() {
        let note = Fixtures.publishableNote()
        let findings = checker.check(note: note, bundle: bundle(for: note), evidence: EvidenceBundle.make(from: note))
        #expect(checker.canPublish(findings))
        #expect(findings.contains { $0.severity == .warning && $0.message.contains("담당자 미확정") })
        #expect(findings.contains { $0.severity == .warning && $0.message.contains("참석자") })
    }

    @Test("요약이 비었거나 항목이 없으면 게시를 막는다")
    func blocksEmptyNote() {
        var note = Fixtures.publishableNote()
        note.summary = ""
        note.decisions = []
        note.actionItems = []
        let findings = checker.check(note: note, bundle: bundle(for: note), evidence: EvidenceBundle.make(from: note))
        #expect(!checker.canPublish(findings))
        #expect(findings.contains { $0.severity == .blocking && $0.message.contains("요약") })
        #expect(findings.contains { $0.severity == .blocking && $0.message.contains("결정사항과 액션아이템") })
    }
}

@Suite("검열 게이트 정밀도")
struct PublishRedactionPrecisionTests {
    /// 실제 실행에서 나온 상황: 모델이 발언을 그대로 옮겨 회의록 항목 본문이 원문 문장과 같아졌다.
    @Test("승인된 항목 본문과 같은 문장은 위반으로 보지 않는다")
    func allowsQuoteThatIsTheApprovedContent() {
        let segment = Fixtures.segment(0, "가격 정책은 아직 정해지지 않았습니다.")
        var note = MeetingNote(meetingId: Fixtures.meetingId, title: "회의", summary: "가격 정책이 미정이다.")
        note.openQuestions = [
            OpenQuestion(
                question: "가격 정책은 아직 정해지지 않았습니다",
                evidence: [Fixtures.evidence(for: segment)],
                confidence: 0.7
            )
        ]
        let evidence = EvidenceBundle.make(from: note)
        let payload = "<ul><li>가격 정책은 아직 정해지지 않았습니다</li></ul>"
        let violations = PublishRedaction.audit(text: payload, evidence: evidence)
        #expect(violations.isEmpty, "\(PublishRedaction.describe(violations))")
    }

    @Test("항목 본문을 넘어서는 원문 문장은 계속 막는다")
    func stillBlocksTranscriptBeyondContent() {
        let segment = Fixtures.segment(
            0,
            "홍길동 님이 배포 체크리스트를 다음 주 월요일까지 공유해 주세요. 그리고 QA는 화요일 오전까지 회귀 테스트를 마쳐야 합니다."
        )
        var note = MeetingNote(meetingId: Fixtures.meetingId, title: "회의", summary: "요약")
        note.actionItems = [
            ActionItem(
                task: "배포 체크리스트 공유",
                evidence: [Fixtures.evidence(for: segment)],
                confidence: 0.8
            )
        ]
        let evidence = EvidenceBundle.make(from: note)
        // 사용자가 전사 문장을 그대로 붙여 넣은 상황
        let payload = "<p>\(segment.text)</p>"
        let violations = PublishRedaction.audit(text: payload, evidence: evidence)
        #expect(violations.contains { $0.kind == .evidenceQuote })
    }
}

@Suite("재생 트랙 선택")
struct PlaybackTrackSelectionTests {
    func track(_ kind: AudioTrackKind) -> AudioTrack {
        AudioTrack(
            meetingId: Fixtures.meetingId,
            kind: kind,
            fileURL: URL(fileURLWithPath: "/tmp/\(kind.rawValue).m4a"),
            duration: 60,
            sampleRate: 48000,
            channelCount: 1,
            byteSize: 100
        )
    }

    @Test("합성본이 있으면 합성본을 재생한다")
    func prefersMixed() {
        let selected = AudioTrack.preferredForPlayback([track(.microphone), track(.system), track(.mixed)])
        #expect(selected?.kind == .mixed)
    }

    @Test("합성본이 없으면 마이크를 재생한다")
    func fallsBackToMicrophone() {
        #expect(AudioTrack.preferredForPlayback([track(.system), track(.microphone)])?.kind == .microphone)
    }

    @Test("트랙이 없으면 선택하지 않는다")
    func handlesEmpty() {
        #expect(AudioTrack.preferredForPlayback([]) == nil)
    }

    @Test("트랙 이름은 사람이 읽을 수 있게 보여준다")
    func displayNames() {
        #expect(track(.mixed).displayName == "전체(합성)")
        #expect(track(.microphone).displayName == "마이크")
        #expect(track(.system).displayName == "시스템 오디오")
    }
}
