import Foundation
@testable import MeetingCore
@testable import MeetingPersistence
import Testing

@Suite("로컬 저장소")
struct RepositoryTests {
    struct Harness {
        var repository: MeetingRepository
        var jobs: ProcessingJobRepository
        var directory: URL
    }

    func makeHarness() throws -> Harness {
        let database = try AppDatabase.inMemory()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("persistence-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Harness(
            repository: MeetingRepository(database: database),
            jobs: ProcessingJobRepository(database: database),
            directory: directory
        )
    }

    func makeMeeting(_ harness: Harness, title: String = "결제 모듈 배포 회의") throws -> Meeting {
        let meeting = Meeting(
            title: title,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_003_600),
            storageDirectory: harness.directory
        )
        try harness.repository.save(meeting)
        return meeting
    }

    func segments(_ meetingId: UUID) -> [TranscriptSegment] {
        [
            TranscriptSegment(
                meetingId: meetingId, index: 0, startTime: 0, endTime: 8,
                text: "안녕하세요. 날씨가 좋네요.", confidence: 0.9
            ),
            TranscriptSegment(
                meetingId: meetingId, index: 1, startTime: 8, endTime: 16,
                text: "결제 모듈 배포는 3월 12일 수요일로 확정합니다.", confidence: 0.95
            )
        ]
    }

    func note(_ meetingId: UUID, evidence: Evidence) -> MeetingNote {
        var note = MeetingNote(meetingId: meetingId, title: "결제 모듈 배포 회의", summary: "배포일 확정")
        note.decisions = [
            Decision(content: "배포를 3월 12일로 확정", kind: .decided, evidence: [evidence], confidence: 0.95, reviewed: true)
        ]
        note.actionItems = [
            ActionItem(
                task: "체크리스트 공유",
                assignee: "홍길동",
                dueDate: nil,
                dueDateNote: "다음 주 월요일",
                status: .confirmed,
                evidence: [evidence],
                confidence: 0.9
            )
        ]
        note.risks = [RiskItem(content: "서버 용량 한계", severity: .high, evidence: [evidence], confidence: 0.7)]
        note.openQuestions = [OpenQuestion(question: "가격 정책 미정", confidence: 0.6)]
        note.topics = [Topic(title: "배포 일정", summary: "3월 배포")]
        note.generation = GenerationSummary(windowCount: 1, thinkingReviewCount: 2, excludedSegmentCount: 1)
        return note
    }

    @Test("회의를 저장하고 다시 읽는다")
    func meetingRoundTrip() throws {
        let harness = try makeHarness()
        let meeting = try makeMeeting(harness)
        let loaded = try harness.repository.meeting(id: meeting.id)
        #expect(loaded?.title == meeting.title)
        #expect(loaded?.status == .recorded)
        #expect(loaded?.storageDirectory.path == harness.directory.path)
        #expect(try Int(#require(loaded?.startedAt.timeIntervalSince1970)) == 1_700_000_000)
        #expect(loaded?.meetingType == .general)
    }

    @Test("회의 유형을 저장하고 다시 읽는다", arguments: MeetingType.allCases)
    func meetingTypeRoundTrip(type: MeetingType) throws {
        let harness = try makeHarness()
        var meeting = try makeMeeting(harness)
        meeting.meetingType = type
        try harness.repository.save(meeting)
        let loaded = try harness.repository.meeting(id: meeting.id)
        #expect(loaded?.meetingType == type)
    }

    @Test("회의록이 근거와 관측값까지 그대로 왕복한다")
    func noteRoundTrip() throws {
        let harness = try makeHarness()
        let meeting = try makeMeeting(harness)
        let segments = segments(meeting.id)
        try harness.repository.save(segments: segments, meetingId: meeting.id)
        let evidence = Evidence(
            segmentId: segments[1].id.uuidString,
            startTime: 8,
            endTime: 16,
            quote: "3월 12일 수요일로 확정합니다"
        )
        try harness.repository.save(note: note(meeting.id, evidence: evidence))

        let loaded = try harness.repository.note(meetingId: meeting.id)
        #expect(loaded?.decisions.count == 1)
        #expect(loaded?.decisions[0].kind == .decided)
        #expect(loaded?.decisions[0].evidence.first?.quote == "3월 12일 수요일로 확정합니다")
        #expect(loaded?.decisions[0].evidence.first?.startTime == 8)
        #expect(loaded?.decisions[0].reviewed == true)
        #expect(loaded?.actionItems[0].assignee == "홍길동")
        #expect(loaded?.actionItems[0].dueDate == nil)
        #expect(loaded?.actionItems[0].dueDateNote == "다음 주 월요일")
        #expect(loaded?.risks[0].severity == .high)
        #expect(loaded?.openQuestions[0].question == "가격 정책 미정")
        #expect(loaded?.topics[0].title == "배포 일정")
        #expect(loaded?.generation.thinkingReviewCount == 2)
    }

    @Test("회의록을 다시 저장하면 이전 항목이 중복되지 않는다")
    func noteSaveIsIdempotent() throws {
        let harness = try makeHarness()
        let meeting = try makeMeeting(harness)
        let evidence = Evidence(segmentId: UUID().uuidString, startTime: 1, endTime: 2, quote: "인용")
        try harness.repository.save(note: note(meeting.id, evidence: evidence))
        try harness.repository.save(note: note(meeting.id, evidence: evidence))
        let loaded = try harness.repository.note(meetingId: meeting.id)
        #expect(loaded?.decisions.count == 1)
        #expect(loaded?.actionItems.count == 1)
    }

    @Test("액션아이템 수정이 저장되고 근거는 유지된다")
    func updatesActionItem() throws {
        let harness = try makeHarness()
        let meeting = try makeMeeting(harness)
        let evidence = Evidence(segmentId: UUID().uuidString, startTime: 8, endTime: 16, quote: "인용")
        try harness.repository.save(note: note(meeting.id, evidence: evidence))

        var item = try #require(harness.repository.note(meetingId: meeting.id)?.actionItems[0])
        item.assignee = "김민수"
        item.dueDate = "2026-03-10"
        item.status = .inProgress
        try harness.repository.update(actionItem: item, meetingId: meeting.id)

        let reloaded = try #require(harness.repository.note(meetingId: meeting.id)?.actionItems[0])
        #expect(reloaded.assignee == "김민수")
        #expect(reloaded.dueDate == "2026-03-10")
        #expect(reloaded.status == .inProgress)
        #expect(reloaded.evidence.first?.startTime == 8)
    }

    @Test("전사문과 사담 판정을 함께 저장하고 판정만 갱신할 수 있다")
    func transcriptAndRelevance() throws {
        let harness = try makeHarness()
        let meeting = try makeMeeting(harness)
        let segments = segments(meeting.id)
        let relevance = [
            RelevanceDecision(segmentId: segments[0].id, label: .exclude, reason: "인사"),
            RelevanceDecision(segmentId: segments[1].id, label: .keep)
        ]
        try harness.repository.save(segments: segments, relevance: relevance, meetingId: meeting.id)

        #expect(try harness.repository.transcript(meetingId: meeting.id).count == 2)
        #expect(try harness.repository.relevance(meetingId: meeting.id).count(where: { $0.label == .exclude }) == 1)

        // 재처리로 판정만 바뀌는 경우
        try harness.repository.updateRelevance([
            RelevanceDecision(segmentId: segments[0].id, label: .condense, reason: "업무 신호 있음")
        ])
        let updated = try harness.repository.relevance(meetingId: meeting.id)
        #expect(updated.first(where: { $0.segmentId == segments[0].id })?.label == .condense)
        // 전사문 원문은 그대로다.
        #expect(try harness.repository.transcript(meetingId: meeting.id)[0].text.contains("안녕하세요"))
    }

    @Test("회의 목록은 요약과 항목 개수를 제공하고 검색이 동작한다")
    func summariesAndSearch() throws {
        let harness = try makeHarness()
        let first = try makeMeeting(harness, title: "결제 모듈 배포 회의")
        let second = try makeMeeting(harness, title: "채용 계획 회의")
        let segments = segments(first.id)
        try harness.repository.save(segments: segments, meetingId: first.id)
        try harness.repository.save(
            note: note(first.id, evidence: Evidence(segmentId: segments[1].id.uuidString, startTime: 8, endTime: 16, quote: "인용"))
        )

        let all = try harness.repository.summaries()
        #expect(all.count == 2)
        let target = try #require(all.first { $0.meeting.id == first.id })
        #expect(target.decisionCount == 1)
        #expect(target.actionItemCount == 1)
        #expect(target.riskCount == 1)
        #expect(target.summaryPreview == "배포일 확정")

        // 전사문 내용으로 검색. 상세에 보여줄 맞춘 문장도 함께 온다.
        let byTranscript = try harness.repository.summaries(matching: "3월 12일")
        #expect(byTranscript.map(\.id) == [first.id])
        #expect(byTranscript.first?.searchHit?.field == .transcript)
        #expect(byTranscript.first?.searchHit?.sentence == "결제 모듈 배포는 3월 12일 수요일로 확정합니다.")
        // 제목으로 검색
        let byTitle = try harness.repository.summaries(matching: "채용")
        #expect(byTitle.map(\.id) == [second.id])
        #expect(byTitle.first?.searchHit?.field == .title)
        #expect(byTitle.first?.searchHit?.sentence == "채용 계획 회의")
        // 액션아이템으로 검색
        let byAction = try harness.repository.summaries(matching: "체크리스트")
        #expect(byAction.map(\.id) == [first.id])
        #expect(byAction.first?.searchHit?.field == .action)
        #expect(byAction.first?.searchHit?.sentence == "체크리스트 공유")
        // 회의록 요약으로 검색
        let byNotes = try harness.repository.summaries(matching: "배포일")
        #expect(byNotes.map(\.id) == [first.id])
        #expect(byNotes.first?.searchHit?.field == .notes)
        #expect(byNotes.first?.searchHit?.sentence == "배포일 확정")
        // 결정사항으로 검색
        let byDecision = try harness.repository.summaries(matching: "배포를 3월 12일로")
        #expect(byDecision.map(\.id) == [first.id])
        #expect(byDecision.first?.searchHit?.field == .decision)
        #expect(byDecision.first?.searchHit?.sentence == "배포를 3월 12일로 확정")
        // 사용자 문서로 고친 회의록도 찾는다.
        var edited = try #require(harness.repository.note(meetingId: first.id))
        edited.customDocument = "보안 검토를 배포 전에 끝낸다."
        try harness.repository.save(note: edited)
        let byDocument = try harness.repository.summaries(matching: "보안 검토")
        #expect(byDocument.map(\.id) == [first.id])
        #expect(byDocument.first?.searchHit?.field == .notes)
        #expect(byDocument.first?.searchHit?.sentence == "보안 검토를 배포 전에 끝낸다.")
        _ = second
    }

    @Test("원본 오디오만 삭제하고 전사문과 회의록은 남긴다")
    func deletesAudioOnly() throws {
        let harness = try makeHarness()
        let meeting = try makeMeeting(harness)
        let audioURL = harness.directory.appendingPathComponent("meeting.m4a")
        try Data("audio".utf8).write(to: audioURL)
        try harness.repository.save(tracks: [
            AudioTrack(
                meetingId: meeting.id, kind: .mixed, fileURL: audioURL,
                duration: 60, sampleRate: 16000, channelCount: 1, byteSize: 5
            )
        ])
        let segments = segments(meeting.id)
        try harness.repository.save(segments: segments, meetingId: meeting.id)
        try harness.repository.save(
            note: note(meeting.id, evidence: Evidence(segmentId: segments[1].id.uuidString, startTime: 8, endTime: 16, quote: "인용"))
        )

        let removed = try harness.repository.deleteAudioFiles(meetingId: meeting.id)
        #expect(removed == 1)
        #expect(!FileManager.default.fileExists(atPath: audioURL.path))
        #expect(try harness.repository.tracks(meetingId: meeting.id).isEmpty)
        // 회의록과 전사문은 유지된다.
        #expect(try harness.repository.transcript(meetingId: meeting.id).count == 2)
        #expect(try harness.repository.note(meetingId: meeting.id)?.decisions.count == 1)
    }

    @Test("회의를 삭제하면 연결된 데이터도 함께 사라진다")
    func cascadeDelete() throws {
        let harness = try makeHarness()
        let meeting = try makeMeeting(harness)
        let segments = segments(meeting.id)
        try harness.repository.save(segments: segments, meetingId: meeting.id)
        try harness.repository.save(
            note: note(meeting.id, evidence: Evidence(segmentId: segments[1].id.uuidString, startTime: 8, endTime: 16, quote: "인용"))
        )
        try harness.repository.delete(meetingId: meeting.id)
        #expect(try harness.repository.meeting(id: meeting.id) == nil)
        #expect(try harness.repository.transcript(meetingId: meeting.id).isEmpty)
        #expect(try harness.repository.note(meetingId: meeting.id) == nil)
    }
}

@Suite("처리 작업 저장소")
struct ProcessingJobRepositoryTests {
    func makeHarness() throws -> (MeetingRepository, ProcessingJobRepository, Meeting) {
        let database = try AppDatabase.inMemory()
        let repository = MeetingRepository(database: database)
        let jobs = ProcessingJobRepository(database: database)
        let meeting = Meeting(
            title: "회의",
            startedAt: Date(),
            storageDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
        )
        try repository.save(meeting)
        return (repository, jobs, meeting)
    }

    @Test("같은 단계는 갱신되고 중복 생성되지 않는다")
    func upsertsByStage() throws {
        let (_, jobs, meeting) = try makeHarness()
        try jobs.upsert(ProcessingJob(meetingId: meeting.id, stage: .transcribe, state: .running, attempt: 1))
        try jobs.upsert(ProcessingJob(meetingId: meeting.id, stage: .transcribe, state: .succeeded, attempt: 2))
        let all = try jobs.jobs(meetingId: meeting.id)
        #expect(all.count == 1)
        #expect(all[0].state == .succeeded)
        #expect(all[0].attempt == 2)
    }

    @Test("앱 강제 종료로 남은 실행 중 작업은 중단 상태가 되어 재처리 대상이 된다")
    func marksInterrupted() throws {
        let (_, jobs, meeting) = try makeHarness()
        try jobs.upsert(ProcessingJob(meetingId: meeting.id, stage: .transcribe, state: .running, attempt: 1))
        let changed = try jobs.markRunningJobsInterrupted()
        #expect(changed == 1)
        #expect(try jobs.job(meetingId: meeting.id, stage: .transcribe)?.state == .interrupted)
        #expect(try jobs.job(meetingId: meeting.id, stage: .transcribe)?.isRetryable == true)
        #expect(try jobs.meetingsNeedingRetry() == [meeting.id])
    }

    @Test("재처리 준비는 실패·중단 작업만 대기 상태로 되돌린다")
    func resetsOnlyFailedJobs() throws {
        let (_, jobs, meeting) = try makeHarness()
        try jobs.upsert(ProcessingJob(meetingId: meeting.id, stage: .prepareAudio, state: .succeeded, attempt: 1))
        try jobs.upsert(
            ProcessingJob(
                meetingId: meeting.id, stage: .transcribe, state: .failed,
                attempt: 1, errorMessage: "모델 로드 실패"
            )
        )
        try jobs.resetForRetry(meetingId: meeting.id)
        #expect(try jobs.job(meetingId: meeting.id, stage: .prepareAudio)?.state == .succeeded)
        let transcribe = try jobs.job(meetingId: meeting.id, stage: .transcribe)
        #expect(transcribe?.state == .pending)
        #expect(transcribe?.errorMessage == nil)
        #expect(try jobs.meetingsNeedingRetry().isEmpty)
    }

    @Test("작업은 처리 순서대로 정렬된다")
    func sortsByStageOrder() throws {
        let (_, jobs, meeting) = try makeHarness()
        for stage in ProcessingStage.allCases.reversed() {
            try jobs.upsert(ProcessingJob(meetingId: meeting.id, stage: stage, state: .succeeded))
        }
        #expect(try jobs.jobs(meetingId: meeting.id).map(\.stage) == ProcessingStage.allCases)
    }
}

@Suite("일정 스킵 저장소")
struct EventSkipRepositoryTests {
    @Test("스킵을 저장하고 해제하면 다시 비운다")
    func skipRoundTripAndUnskip() throws {
        let calendar = try CalendarRepository(database: AppDatabase.inMemory())
        let start = Date(timeIntervalSince1970: 1_772_000_000)
        let event = CalendarEvent(
            id: "weekly#1",
            seriesId: "series-weekly",
            title: "주간 스탠드업",
            startDate: start,
            endDate: start.addingTimeInterval(1800)
        )
        let record = EventSkipPolicy.record(for: event, scope: .series, at: start)

        try calendar.upsertSkip(record)
        let loaded = try calendar.skipRecords()
        #expect(loaded.count == 1)
        #expect(loaded.first?.scope == .series)
        #expect(loaded.first?.seriesId == "series-weekly")
        #expect(try calendar.event(id: event.id) == nil)

        try calendar.removeSkips(matching: event)
        #expect(try calendar.skipRecords().isEmpty)
    }

    @Test("일정 메타데이터는 seriesId를 함께 저장한다")
    func savesSeriesIdWithEvent() throws {
        let calendar = try CalendarRepository(database: AppDatabase.inMemory())
        let start = Date(timeIntervalSince1970: 1_772_000_000)
        let event = CalendarEvent(
            id: "weekly#1",
            seriesId: "series-weekly",
            title: "주간 스탠드업",
            startDate: start,
            endDate: start.addingTimeInterval(1800)
        )
        try calendar.save(events: [event])
        #expect(try calendar.event(id: "weekly#1")?.seriesId == "series-weekly")
    }
}
