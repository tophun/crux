import Foundation
import MeetingCore
import SwiftData

/// 회의 데이터 저장소. 모든 읽기·쓰기는 SwiftData ModelContext를 통해 로컬에만 일어난다.
public struct MeetingRepository: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - 회의

    public func save(_ meeting: Meeting) throws {
        try database.write { context in
            if let model = try context.all(MeetingModel.self).first(where: { $0.id == meeting.id.uuidString }) {
                model.title = meeting.title
                model.startedAt = meeting.startedAt
                model.endedAt = meeting.endedAt
                model.status = meeting.status.rawValue
                model.storageDirectory = meeting.storageDirectory.path
                model.source = meeting.source.rawValue
                model.createdAt = meeting.createdAt
                model.updatedAt = meeting.updatedAt
            } else {
                context.insert(MeetingModel(meeting))
            }
        }
    }

    public func meeting(id: UUID) throws -> Meeting? {
        try database.read { context in
            try context.all(MeetingModel.self)
                .first(where: { $0.id == id.uuidString })?
                .domain
        }
    }

    public func updateStatus(_ status: MeetingStatus, meetingId: UUID) throws {
        try database.write { context in
            guard let model = try context.all(MeetingModel.self)
                .first(where: { $0.id == meetingId.uuidString }) else { return }
            model.status = status.rawValue
            model.updatedAt = Date()
        }
    }

    public func delete(meetingId: UUID) throws {
        try database.write { context in
            let key = meetingId.uuidString
            for model in try context.all(AudioTrackModel.self).filter({ $0.meetingId == key }) {
                context.delete(model)
            }
            for model in try context.all(TranscriptSegmentModel.self).filter({ $0.meetingId == key }) {
                context.delete(model)
            }
            for model in try context.all(NoteModel.self).filter({ $0.meetingId == key }) {
                context.delete(model)
            }
            for model in try context.all(DecisionModel.self).filter({ $0.meetingId == key }) {
                context.delete(model)
            }
            for model in try context.all(ActionItemModel.self).filter({ $0.meetingId == key }) {
                context.delete(model)
            }
            for model in try context.all(OpenQuestionModel.self).filter({ $0.meetingId == key }) {
                context.delete(model)
            }
            for model in try context.all(RiskItemModel.self).filter({ $0.meetingId == key }) {
                context.delete(model)
            }
            for model in try context.all(TopicModel.self).filter({ $0.meetingId == key }) {
                context.delete(model)
            }
            for model in try context.all(ProcessingJobModel.self).filter({ $0.meetingId == key }) {
                context.delete(model)
            }
            for model in try context.all(PublishRecordModel.self).filter({ $0.meetingId == key }) {
                context.delete(model)
            }
            if let meeting = try context.all(MeetingModel.self).first(where: { $0.id == key }) {
                context.delete(meeting)
            }
        }
    }

    /// 회의 목록. 최근 회의가 먼저 온다.
    public func summaries(matching query: String? = nil) throws -> [MeetingSummary] {
        try database.read { context in
            var meetings = try context.all(MeetingModel.self)
                .compactMap(\.domain)
                .sorted { $0.startedAt > $1.startedAt }
            let notes = try context.all(NoteModel.self)
            let tracks = try context.all(TranscriptSegmentModel.self)
            let decisions = try context.all(DecisionModel.self)
            let actions = try context.all(ActionItemModel.self)
            let questions = try context.all(OpenQuestionModel.self)
            let risks = try context.all(RiskItemModel.self)

            if let query, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
                let matchingIds = Set(
                    tracks.filter { $0.text.lowercased().contains(needle) }.map(\.meetingId)
                        + actions.filter { $0.task.lowercased().contains(needle) }.map(\.meetingId)
                        + decisions.filter { $0.content.lowercased().contains(needle) }.map(\.meetingId)
                        + notes.filter {
                            $0.title.lowercased().contains(needle) || $0.summary.lowercased().contains(needle)
                        }.map(\.meetingId)
                )
                meetings = meetings.filter {
                    matchingIds.contains($0.id.uuidString) || $0.title.lowercased().contains(needle)
                }
            }

            let notesByMeeting = Dictionary(notes.map { ($0.meetingId, $0) }, uniquingKeysWith: { first, _ in first })
            func countByMeeting(_ models: [String]) -> [String: Int] {
                Dictionary(grouping: models, by: { $0 }).mapValues(\.count)
            }
            let decisionCounts = countByMeeting(decisions.map(\.meetingId))
            let actionCounts = countByMeeting(actions.map(\.meetingId))
            let questionCounts = countByMeeting(questions.map(\.meetingId))
            let riskCounts = countByMeeting(risks.map(\.meetingId))

            return meetings.map { meeting in
                let key = meeting.id.uuidString
                return MeetingSummary(
                    meeting: meeting,
                    noteTitle: notesByMeeting[key]?.title,
                    summaryPreview: notesByMeeting[key]?.summary,
                    decisionCount: decisionCounts[key] ?? 0,
                    actionItemCount: actionCounts[key] ?? 0,
                    openQuestionCount: questionCounts[key] ?? 0,
                    riskCount: riskCounts[key] ?? 0
                )
            }
        }
    }

    // MARK: - 오디오 트랙

    public func save(tracks: [AudioTrack]) throws {
        try database.write { context in
            let existing = try context.all(AudioTrackModel.self)
            for track in tracks {
                if let model = existing.first(where: { $0.id == track.id.uuidString }) {
                    model.meetingId = track.meetingId.uuidString
                    model.kind = track.kind.rawValue
                    model.filePath = track.fileURL.path
                    model.duration = track.duration
                    model.sampleRate = track.sampleRate
                    model.channelCount = track.channelCount
                    model.byteSize = track.byteSize
                    model.createdAt = track.createdAt
                } else {
                    context.insert(AudioTrackModel(track))
                }
            }
        }
    }

    public func tracks(meetingId: UUID) throws -> [AudioTrack] {
        try database.read { context in
            try context.all(AudioTrackModel.self)
                .filter { $0.meetingId == meetingId.uuidString }
                .compactMap(\.domain)
        }
    }

    /// 원본 오디오 삭제(§11). 회의록과 전사문은 남긴다.
    @discardableResult
    public func deleteAudioFiles(meetingId: UUID, fileManager: FileManager = .default) throws -> Int {
        let tracks = try tracks(meetingId: meetingId)
        var removed = 0
        for track in tracks where fileManager.fileExists(atPath: track.fileURL.path) {
            try fileManager.removeItem(at: track.fileURL)
            removed += 1
        }
        try database.write { context in
            for model in try context.all(AudioTrackModel.self).filter({ $0.meetingId == meetingId.uuidString }) {
                context.delete(model)
            }
        }
        return removed
    }

    /// 트랙 기록만 지운다. 파일 삭제는 호출한 쪽에서 정책에 맞게 처리한다.
    public func deleteTrackRows(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        let keys = Set(ids.map(\.uuidString))
        try database.write { context in
            for model in try context.all(AudioTrackModel.self).filter({ keys.contains($0.id) }) {
                context.delete(model)
            }
        }
    }

    /// 오디오 자동 삭제 판단에 필요한 값만 모아 온다(§11).
    public func audioRetentionCandidates() throws -> [AudioRetentionPolicy.Candidate] {
        try database.read { context in
            let meetings = try context.all(MeetingModel.self)
            let tracks = try context.all(AudioTrackModel.self)
            let notes = try context.all(NoteModel.self)
            return meetings.compactMap { model in
                guard let id = UUID(uuidString: model.id) else { return nil }
                return AudioRetentionPolicy.Candidate(
                    meetingId: id,
                    referenceDate: model.endedAt ?? model.createdAt,
                    isCompleted: MeetingStatus(rawValue: model.status) == .completed
                        && notes.contains { $0.meetingId == model.id },
                    hasAudio: tracks.contains { $0.meetingId == model.id }
                )
            }
        }
    }

    /// 저장된 오디오 사용량. 설정 화면에 보여 준다.
    public func audioStorageUsage() throws -> (trackCount: Int, bytes: Int64) {
        try database.read { context in
            let tracks = try context.all(AudioTrackModel.self)
            return (tracks.count, tracks.reduce(into: Int64(0)) { $0 += $1.byteSize })
        }
    }

    // MARK: - 전사문

    public func save(
        segments: [TranscriptSegment],
        relevance: [RelevanceDecision] = [],
        meetingId: UUID
    ) throws {
        let labels = Dictionary(relevance.map { ($0.segmentId, $0) }, uniquingKeysWith: { first, _ in first })
        try database.write { context in
            for model in try context.all(TranscriptSegmentModel.self).filter({ $0.meetingId == meetingId.uuidString }) {
                context.delete(model)
            }
            for segment in segments {
                context.insert(TranscriptSegmentModel(segment, relevance: labels[segment.id]))
            }
        }
    }

    /// 사담 판정만 갱신한다. 전사문 원문은 그대로 보존된다(§9).
    public func updateRelevance(_ relevance: [RelevanceDecision]) throws {
        let byID = Dictionary(relevance.map { ($0.segmentId.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        try database.write { context in
            for model in try context.all(TranscriptSegmentModel.self) {
                guard let decision = byID[model.id] else { continue }
                model.relevanceLabel = decision.label.rawValue
                model.relevanceReason = decision.reason
            }
        }
    }

    public func transcript(meetingId: UUID) throws -> [TranscriptSegment] {
        try database.read { context in
            try context.all(TranscriptSegmentModel.self)
                .filter { $0.meetingId == meetingId.uuidString }
                .sorted { $0.segmentIndex < $1.segmentIndex }
                .compactMap(\.domain)
        }
    }

    public func relevance(meetingId: UUID) throws -> [RelevanceDecision] {
        try database.read { context in
            try context.all(TranscriptSegmentModel.self)
                .filter { $0.meetingId == meetingId.uuidString }
                .sorted { $0.segmentIndex < $1.segmentIndex }
                .compactMap(\.relevance)
        }
    }

    // MARK: - 회의록

    public func save(note: MeetingNote) throws {
        try database.write { context in
            let key = note.meetingId.uuidString
            for model in try context.all(DecisionModel.self).filter({ $0.meetingId == key }) {
                context.delete(model)
            }
            for model in try context.all(ActionItemModel.self).filter({ $0.meetingId == key }) {
                context.delete(model)
            }
            for model in try context.all(OpenQuestionModel.self).filter({ $0.meetingId == key }) {
                context.delete(model)
            }
            for model in try context.all(RiskItemModel.self).filter({ $0.meetingId == key }) {
                context.delete(model)
            }
            for model in try context.all(TopicModel.self).filter({ $0.meetingId == key }) {
                context.delete(model)
            }
            for model in try context.all(NoteModel.self).filter({ $0.meetingId == key }) {
                context.delete(model)
            }
            context.insert(NoteModel(note))
            for (index, decision) in note.decisions.enumerated() {
                context.insert(DecisionModel(decision, meetingId: note.meetingId, position: index))
            }
            for (index, item) in note.actionItems.enumerated() {
                context.insert(ActionItemModel(item, meetingId: note.meetingId, position: index))
            }
            for (index, item) in note.openQuestions.enumerated() {
                context.insert(OpenQuestionModel(item, meetingId: note.meetingId, position: index))
            }
            for (index, item) in note.risks.enumerated() {
                context.insert(RiskItemModel(item, meetingId: note.meetingId, position: index))
            }
            for (index, topic) in note.topics.enumerated() {
                context.insert(TopicModel(topic, meetingId: note.meetingId, position: index))
            }
        }
    }

    public func note(meetingId: UUID) throws -> MeetingNote? {
        try database.read { context in
            let key = meetingId.uuidString
            guard let record = try context.all(NoteModel.self).first(where: { $0.meetingId == key }) else {
                return nil
            }
            var note = MeetingNote(
                meetingId: meetingId,
                title: record.title,
                summary: record.summary,
                generatedAt: record.generatedAt,
                generation: JSONColumn.decode(GenerationSummary.self, from: record.generationJSON)
                    ?? GenerationSummary(),
                customDocument: record.customDocument
            )
            note.decisions = try context.all(DecisionModel.self)
                .filter { $0.meetingId == key }.sorted { $0.position < $1.position }.compactMap(\.domain)
            note.actionItems = try context.all(ActionItemModel.self)
                .filter { $0.meetingId == key }.sorted { $0.position < $1.position }.compactMap(\.domain)
            note.openQuestions = try context.all(OpenQuestionModel.self)
                .filter { $0.meetingId == key }.sorted { $0.position < $1.position }.compactMap(\.domain)
            note.risks = try context.all(RiskItemModel.self)
                .filter { $0.meetingId == key }.sorted { $0.position < $1.position }.compactMap(\.domain)
            note.topics = try context.all(TopicModel.self)
                .filter { $0.meetingId == key }.sorted { $0.position < $1.position }.compactMap(\.domain)
            return note
        }
    }

    /// 액션아이템 사용자 수정(§11).
    public func update(actionItem: ActionItem, meetingId: UUID) throws {
        try database.write { context in
            guard let existing = try context.all(ActionItemModel.self)
                .first(where: { $0.id == actionItem.id.uuidString && $0.meetingId == meetingId.uuidString }) else {
                throw PersistenceError.notFound("actionItem \(actionItem.id)")
            }
            existing.task = actionItem.task
            existing.assignee = actionItem.assignee
            existing.dueDate = actionItem.dueDate
            existing.dueDateNote = actionItem.dueDateNote
            existing.status = actionItem.status.rawValue
            existing.evidenceJSON = JSONColumn.encode(actionItem.evidence)
            existing.confidence = actionItem.confidence
            existing.reviewed = actionItem.reviewed
        }
    }

    public func update(decision: Decision, meetingId: UUID) throws {
        try database.write { context in
            guard let existing = try context.all(DecisionModel.self)
                .first(where: { $0.id == decision.id.uuidString && $0.meetingId == meetingId.uuidString }) else {
                throw PersistenceError.notFound("decision \(decision.id)")
            }
            existing.content = decision.content
            existing.kind = decision.kind.rawValue
            existing.evidenceJSON = JSONColumn.encode(decision.evidence)
            existing.confidence = decision.confidence
            existing.reviewed = decision.reviewed
        }
    }
}

public enum PersistenceError: Error, LocalizedError, Sendable {
    case notFound(String)
    case migrationFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .notFound(what): "저장된 항목을 찾을 수 없습니다: \(what)"
        case let .migrationFailed(reason): "기존 저장소를 SwiftData로 옮기지 못했습니다: \(reason)"
        }
    }
}
