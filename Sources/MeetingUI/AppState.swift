import Foundation
import MeetingCore
import MeetingPersistence
import MeetingPipeline
import Observation

/// 회의 상세 화면에 필요한 데이터 묶음.
public struct MeetingDetail: Sendable {
    public var meeting: Meeting
    public var note: MeetingNote?
    public var segments: [TranscriptSegment]
    public var relevance: [RelevanceDecision]
    public var jobs: [ProcessingJob]
    public var tracks: [AudioTrack]
    /// 캘린더에서 가져온 참석자. 없으면 비워 두고 임의로 만들지 않는다.
    public var attendees: [String]
    /// 녹음 중 노치에서 남긴 메모.
    public var memos: [MeetingMemo] = []

    public init(
        meeting: Meeting,
        note: MeetingNote? = nil,
        segments: [TranscriptSegment] = [],
        relevance: [RelevanceDecision] = [],
        jobs: [ProcessingJob] = [],
        tracks: [AudioTrack] = [],
        attendees: [String] = []
    ) {
        self.meeting = meeting
        self.note = note
        self.segments = segments
        self.relevance = relevance
        self.jobs = jobs
        self.tracks = tracks
        self.attendees = attendees
    }

    /// 사담으로 제외된 구간을 표시하기 위한 매핑
    public var relevanceBySegment: [UUID: RelevanceLabel] {
        Dictionary(relevance.map { ($0.segmentId, $0.label) }, uniquingKeysWith: { first, _ in first })
    }
}

/// 컨텐츠 영역에 보여 줄 화면. 툴바 왼쪽 버튼으로 바꾼다.
public enum DetailTab: String, CaseIterable, Sendable {
    case preview
    case transcript
}

/// 앱 상태. 모든 데이터는 로컬 저장소에서만 온다.
@MainActor
@Observable
public final class AppState {
    public private(set) var summaries: [MeetingSummary] = []
    public var searchText: String = "" {
        didSet { reload() }
    }

    /// 목록에서 고른 회의가 검색어와 맞춘 문장. 검색 중이 아니면 nil.
    public var selectedSearchHit: MeetingSearch.Hit? {
        guard MeetingSearch.normalizedQuery(searchText) != nil else { return nil }
        return summaries.first { $0.id == selectedMeetingId }?.searchHit
    }

    public var selectedMeetingId: UUID? {
        didSet { loadDetail() }
    }

    public private(set) var detail: MeetingDetail?
    /// 미리보기 / 전사문 화면 전환.
    public var detailTab: DetailTab = .preview
    /// 미리보기의 편집 모드. 켜져 있는 동안 제목도 함께 고칠 수 있다.
    public var isEditingDocument = false
    public private(set) var progress: MeetingProcessingPipeline.Update?
    public private(set) var isProcessing = false
    public private(set) var statusMessage: String?
    public private(set) var errorMessage: String?
    public private(set) var logLines: [String] = []

    /// 삭제 확인을 기다리는 회의. UI가 확인 대화상자를 띄운다.
    public var pendingDeletion: MeetingSummary?

    private let repository: MeetingRepository
    private let jobs: ProcessingJobRepository
    private let pipeline: MeetingProcessingPipeline
    private let importer: MeetingImporter
    private let deleter: MeetingDeleter
    /// 참석자 조회용. 캘린더를 쓰지 않는 실행(테스트·CLI)에서는 nil이다.
    private let calendar: CalendarRepository?
    /// 회의 오디오 재생. 근거 타임스탬프에서 바로 들을 수 있게 한다.
    public let playback: AudioPlaybackController
    private var processingTask: Task<Void, Never>?

    public init(
        repository: MeetingRepository,
        jobs: ProcessingJobRepository,
        pipeline: MeetingProcessingPipeline,
        importer: MeetingImporter,
        deleter: MeetingDeleter,
        calendar: CalendarRepository? = nil,
        playback: AudioPlaybackController? = nil
    ) {
        self.repository = repository
        self.jobs = jobs
        self.pipeline = pipeline
        self.importer = importer
        self.deleter = deleter
        self.calendar = calendar
        self.playback = playback ?? AudioPlaybackController()
        // 지난 실행에서 중단된 작업을 재처리 대상으로 표시한다.
        try? jobs.markRunningJobsInterrupted()
        reload()
    }

    // MARK: - 조회

    public func reload() {
        do {
            summaries = try repository.summaries(matching: MeetingSearch.normalizedQuery(searchText))
            errorMessage = nil
            // 목록이 비어 있지 않으면 항상 하나는 선택돼 있어야 한다.
            // 선택이 없거나(첫 실행), 선택했던 회의가 삭제·검색으로 사라졌으면 가장 최근 회의를 고른다.
            if selectedMeetingId == nil || !summaries.contains(where: { $0.id == selectedMeetingId }) {
                selectedMeetingId = summaries.first?.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func loadDetail() {
        guard let id = selectedMeetingId else {
            detail = nil
            playback.unload()
            return
        }
        do {
            guard let meeting = try repository.meeting(id: id) else {
                detail = nil
                return
            }
            // 데이터 폴더가 옮겨졌을 수 있으므로 현재 위치로 경로를 맞춘다.
            let tracks = try repository.tracks(meetingId: id).map {
                MeetingProcessingPipeline.resolveAudioFile(for: $0, meetingId: id)
            }
            detail = try MeetingDetail(
                meeting: meeting,
                note: repository.note(meetingId: id),
                segments: repository.transcript(meetingId: id),
                relevance: repository.relevance(meetingId: id),
                jobs: jobs.jobs(meetingId: id),
                tracks: tracks,
                attendees: attendees(meetingId: id)
            )
            detail?.memos = MeetingMemoStore(storageDirectory: meeting.storageDirectory).load()
            playback.prepare(tracks: tracks)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 연결된 캘린더 일정의 참석자. 조회에 실패해도 회의록 표시를 막지 않는다.
    private func attendees(meetingId: UUID) -> [String] {
        guard let calendar else { return [] }
        guard let eventId = try? calendar.linkedEventId(meetingId: meetingId),
              let event = try? calendar.event(id: eventId) else { return [] }
        return event.attendeeDisplayNames
    }

    public var retryableMeetings: [MeetingSummary] {
        summaries.filter { $0.meeting.status == .failed }
    }

    public var lastCompletedMeeting: MeetingSummary? {
        summaries.first { $0.meeting.status == .completed }
    }

    // MARK: - 동작

    /// 로컬 오디오 파일을 가져와 바로 처리한다 (Phase 1 흐름).
    public func importAndProcess(url: URL) {
        do {
            let imported = try importer.importAudio(at: url)
            reload()
            selectedMeetingId = imported.meeting.id
            process(meetingId: imported.meeting.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func process(meetingId: UUID, force: Bool = false) {
        guard !isProcessing else {
            statusMessage = "이미 처리 중입니다."
            return
        }
        isProcessing = true
        errorMessage = nil
        statusMessage = "처리를 시작합니다."
        logLines = []

        processingTask = Task { [pipeline] in
            do {
                let result = try await pipeline.process(
                    meetingId: meetingId,
                    force: force,
                    onUpdate: { [weak self] update in
                        Task { @MainActor [weak self] in
                            self?.progress = update
                            self?.statusMessage = update.message
                        }
                    }
                )
                await MainActor.run {
                    self.isProcessing = false
                    self.progress = nil
                    self.statusMessage = "회의록 생성 완료"
                    self.logLines = result.metrics.map(\.description) + result.problems.prefix(20).map { "· \($0)" }
                    self.reload()
                    self.loadDetail()
                }
            } catch is CancellationError {
                await MainActor.run { self.finishCancelled(meetingId: meetingId) }
            } catch {
                await MainActor.run {
                    self.isProcessing = false
                    self.progress = nil
                    if Task.isCancelled {
                        self.finishCancelled(meetingId: meetingId)
                        return
                    }
                    self.errorMessage = error.localizedDescription
                    self.statusMessage = "처리 실패 — 다시 처리할 수 있습니다."
                    self.reload()
                    self.loadDetail()
                }
            }
        }
    }

    /// 취소로 끝났을 때의 뒷정리. 회의를 처리 대기 상태로 되돌려 다시 생성할 수 있게 한다.
    private func finishCancelled(meetingId: UUID) {
        isProcessing = false
        progress = nil
        errorMessage = nil
        if let meeting = try? repository.meeting(id: meetingId), meeting.status != .completed {
            try? repository.updateStatus(.recorded, meetingId: meetingId)
        }
        statusMessage = "회의록 생성을 취소했습니다."
        reload()
        loadDetail()
    }

    /// 진행 중인 회의록 생성을 멈춘다.
    ///
    /// 실제 중단은 다음 단계 경계에서 일어난다. 이미 끝난 단계의 결과(전사문 등)는 남으므로
    /// 다시 생성하면 그 지점부터 이어서 처리한다.
    public func cancelProcessing() {
        guard isProcessing else { return }
        processingTask?.cancel()
        statusMessage = "취소하는 중… 진행 중인 단계가 끝나면 멈춥니다."
    }

    public func retry(meetingId: UUID) {
        try? jobs.resetForRetry(meetingId: meetingId)
        process(meetingId: meetingId)
    }

    // MARK: - 산출물 수정

    //
    // 회의록은 초안이다. 사용자가 고친 내용이 최종본이며, 근거는 그대로 남는다(§11).
    // 전사문은 기록 원본이므로 수정 대상이 아니다.

    /// 회의 제목. 목록과 회의록 문서가 같은 제목을 쓰도록 둘 다 바꾼다.
    public func updateTitle(_ title: String, meetingId: UUID) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            if var meeting = try repository.meeting(id: meetingId), meeting.title != trimmed {
                meeting.title = trimmed
                meeting.updatedAt = Date()
                try repository.save(meeting)
            }
            if var note = try repository.note(meetingId: meetingId), note.title != trimmed {
                note.title = trimmed
                try repository.save(note: note)
            }
            reload()
            loadDetail()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 회의록 내용을 바꾼 뒤 저장한다. 바꿀 것이 없으면 아무것도 하지 않는다.
    private func editNote(meetingId: UUID, _ change: (inout MeetingNote) -> Void) {
        do {
            guard var note = try repository.note(meetingId: meetingId) else {
                statusMessage = "수정할 회의록이 없습니다."
                return
            }
            let before = note
            change(&note)
            guard note != before else { return }
            // 내용이 바뀌면 프롬프트로 구성한 문서는 낡는다. 비워서 기본 구성으로 되돌린다.
            note.customDocument = nil
            try repository.save(note: note)
            statusMessage = "수정 내용을 저장했습니다."
            reload()
            loadDetail()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 미리보기에서 직접 고친 문서를 저장한다. 이후 표시·복사·공유·내보내기가 모두 이 문서를 쓴다.
    ///
    /// 비워서 저장하면 기본 구성으로 되돌아간다.
    public func updateDocument(_ markdown: String, meetingId: UUID) {
        do {
            guard var note = try repository.note(meetingId: meetingId) else {
                statusMessage = "수정할 회의록이 없습니다."
                return
            }
            let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            note.customDocument = trimmed.isEmpty ? nil : trimmed
            try repository.save(note: note)
            statusMessage = "문서를 저장했습니다."
            loadDetail()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func updateSummary(_ summary: String, meetingId: UUID) {
        editNote(meetingId: meetingId) { $0.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    public func updateDecisions(_ decisions: [Decision], meetingId: UUID) {
        editNote(meetingId: meetingId) { $0.decisions = decisions }
    }

    public func updateRisks(_ risks: [RiskItem], meetingId: UUID) {
        editNote(meetingId: meetingId) { $0.risks = risks }
    }

    public func updateOpenQuestions(_ questions: [OpenQuestion], meetingId: UUID) {
        editNote(meetingId: meetingId) { $0.openQuestions = questions }
    }

    public func updateActionItems(_ items: [ActionItem], meetingId: UUID) {
        editNote(meetingId: meetingId) { $0.actionItems = items }
    }

    public func update(actionItem: ActionItem) {
        guard let meetingId = detail?.meeting.id else { return }
        do {
            try repository.update(actionItem: actionItem, meetingId: meetingId)
            loadDetail()
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 근거 타임스탬프나 전사 구간을 눌렀을 때 그 지점부터 재생한다.
    public func play(from time: TimeInterval) {
        guard playback.isLoaded else {
            statusMessage = playback.errorMessage ?? "재생할 오디오가 없습니다."
            return
        }
        playback.seek(to: time)
    }

    // MARK: - 삭제

    /// 삭제 확인을 요청한다. 확인 없이는 지우지 않는다.
    public func requestDelete(meetingId: UUID) {
        pendingDeletion = summaries.first { $0.id == meetingId }
    }

    public func cancelDelete() {
        pendingDeletion = nil
    }

    /// 회의를 삭제한다. 오디오·전사문·회의록·근거 파일이 함께 사라진다(파일은 휴지통).
    public func confirmDelete() {
        guard let target = pendingDeletion else { return }
        pendingDeletion = nil
        guard !isProcessing else {
            statusMessage = "처리 중에는 삭제할 수 없습니다. 끝난 뒤에 다시 시도하세요."
            return
        }
        do {
            let summary = try deleter.delete(meetingId: target.id)
            if selectedMeetingId == target.id {
                selectedMeetingId = nil
                detail = nil
            }
            var message = "‘\(summary.meetingTitle)’를 삭제했습니다. 파일은 휴지통으로 보냈습니다."
            if !summary.keptExternalFiles.isEmpty {
                message += " 가져온 원본 파일 \(summary.keptExternalFiles.count)개는 그대로 두었습니다."
            }
            statusMessage = message
            errorMessage = nil
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 회의록 내보내기. 로컬 파일로만 저장한다.
    @discardableResult
    public func export(meetingId: UUID, format: ExportFormat, to directory: URL) -> URL? {
        do {
            guard let meeting = try repository.meeting(id: meetingId),
                  let note = try repository.note(meetingId: meetingId)
            else {
                statusMessage = "내보낼 회의록이 없습니다."
                return nil
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let base = meeting.title.replacingOccurrences(of: "/", with: "-")
            switch format {
            case .markdown:
                let url = directory.appendingPathComponent("\(base).md")
                try MeetingNoteExporter.document(note, meeting: meeting, attendees: attendees(meetingId: meetingId))
                    .write(to: url, atomically: true, encoding: .utf8)
                statusMessage = "내보냈습니다: \(url.path)"
                return url
            case .json:
                let url = directory.appendingPathComponent("\(base).json")
                try MeetingNoteExporter.json(note).write(to: url, options: .atomic)
                statusMessage = "내보냈습니다: \(url.path)"
                return url
            }
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    public enum ExportFormat: String, CaseIterable, Sendable {
        case markdown
        case json

        public var displayName: String {
            switch self {
            case .markdown: "Markdown"
            case .json: "JSON"
            }
        }
    }
}
