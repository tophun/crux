import Foundation

/// `confluence-writer` + `jira-task-writer` Skill.
///
/// 회의록과 캘린더 메타데이터로 게시 초안을 만든다.
/// 근거·타임스탬프·전사 원문은 **구조적으로** 들어갈 수 없다(`ConfluencePageDraft`/`JiraIssueDraft` 필드에 없음).
public struct PublishBundleBuilder: Sendable {
    public struct Options: Sendable {
        public var spaceKey: String
        public var projectKey: String
        public var defaultIssueType: String
        public var defaultPriority: String?
        /// 담당자가 확정되지 않은 액션아이템도 이슈로 만들지
        public var includeUnassigned: Bool

        public init(
            spaceKey: String,
            projectKey: String,
            defaultIssueType: String = "Task",
            defaultPriority: String? = nil,
            includeUnassigned: Bool = true
        ) {
            self.spaceKey = spaceKey
            self.projectKey = projectKey
            self.defaultIssueType = defaultIssueType
            self.defaultPriority = defaultPriority
            self.includeUnassigned = includeUnassigned
        }
    }

    public init() {}

    public func build(
        note: MeetingNote,
        meeting: Meeting,
        event: CalendarEvent?,
        options: Options,
        calendar: Calendar = .current
    ) -> PublishBundle {
        // 제목·날짜·참석자는 캘린더 정보를 우선한다.
        let title = event?.title ?? (note.title.isEmpty ? meeting.title : note.title)
        let startDate = event?.startDate ?? meeting.startedAt
        let attendees = event?.attendeeDisplayNames ?? []

        let decided = note.decisions.filter { $0.kind == .decided }
        let proposals = note.decisions.filter { $0.kind == .proposed }

        var discussion = note.topics.map {
            ConfluencePageDraft.DiscussionLine(topic: $0.title, detail: $0.summary)
        }
        // 확정되지 않은 제안은 결정사항이 아니라 논의 내용에 남긴다.
        discussion += proposals.map {
            ConfluencePageDraft.DiscussionLine(topic: "검토 중", detail: $0.content)
        }

        let page = ConfluencePageDraft(
            title: title,
            meetingDate: Self.dateText(startDate, calendar: calendar),
            attendees: attendees,
            summary: note.summary,
            decisions: decided.map(\.content),
            actionItems: note.actionItems.map {
                ConfluencePageDraft.ActionLine(
                    task: $0.task,
                    assignee: $0.assigneeDisplay,
                    dueDate: $0.dueDateDisplay
                )
            },
            discussion: discussion,
            risks: note.risks.map(\.content),
            openQuestions: note.openQuestions.map(\.question)
        )

        let issues: [JiraIssueDraft] = note.actionItems.enumerated().map { index, item in
            var details: [String] = ["회의: \(title)", "회의 날짜: \(Self.dateText(startDate, calendar: calendar))"]
            if !note.summary.isEmpty {
                details.append("회의 요약: \(note.summary)")
            }
            let jiraDueDate = KoreanDateParser.jiraDueDate(item.dueDate, reference: startDate, calendar: calendar)
            if jiraDueDate == nil, let expression = item.dueDate ?? item.dueDateNote {
                details.append("회의에서 나온 기한 표현: \(expression) (실제 날짜 확인 필요)")
            }
            if item.assignee == nil {
                details.append("담당자가 회의에서 확인되지 않았습니다. 배정 전에 확인이 필요합니다.")
            }
            return JiraIssueDraft(
                contentId: ContentId.actionItem(index),
                summary: Self.issueSummary(item.task),
                detailParagraphs: details,
                projectKey: options.projectKey,
                issueTypeName: options.defaultIssueType,
                assigneeQuery: item.assignee,
                dueDate: jiraDueDate,
                priorityName: options.defaultPriority,
                include: options.includeUnassigned || item.assignee != nil
            )
        }

        return PublishBundle(
            meetingId: note.meetingId,
            page: page,
            issues: issues,
            spaceKey: options.spaceKey,
            projectKey: options.projectKey
        )
    }

    /// 회의 날짜 표기. 캘린더 이벤트 시각을 우선 사용한다.
    static func dateText(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy년 M월 d일 (E) HH:mm"
        return formatter.string(from: date)
    }

    /// Jira 요약 필드는 한 줄이어야 하고 길이 제한이 있다.
    static func issueSummary(_ task: String) -> String {
        let single = task
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return single.count <= 240 ? single : String(single.prefix(237)) + "…"
    }
}

/// `meeting-quality-checker` Skill. 게시 전에 회의록이 게시 가능한 상태인지 본다.
public struct MeetingQualityChecker: Sendable {
    public struct Finding: Hashable, Sendable, Codable {
        public var severity: Severity
        public var message: String

        public enum Severity: String, Sendable, Codable {
            /// 게시를 막는 문제
            case blocking
            /// 사용자 확인이 필요한 문제
            case warning
        }
    }

    public init() {}

    public func check(note: MeetingNote, bundle: PublishBundle, evidence: EvidenceBundle) -> [Finding] {
        var findings: [Finding] = []

        if note.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            findings.append(Finding(severity: .blocking, message: "회의 요약이 비어 있습니다."))
        }
        if note.decisions.isEmpty, note.actionItems.isEmpty {
            findings.append(Finding(severity: .blocking, message: "결정사항과 액션아이템이 모두 없습니다."))
        }
        if bundle.page.attendees.isEmpty {
            findings.append(Finding(severity: .warning, message: "캘린더 참석자 정보가 없어 참석자란이 비어 있습니다."))
        }
        for decision in note.decisions where decision.kind == .decided && decision.evidence.isEmpty {
            findings.append(
                Finding(severity: .warning, message: "근거 없는 결정사항: \(String(decision.content.prefix(24)))")
            )
        }
        for item in note.actionItems where item.assignee == nil {
            findings.append(
                Finding(severity: .warning, message: "담당자 미확정 액션아이템: \(String(item.task.prefix(24)))")
            )
        }
        for issue in bundle.includedIssues where issue.summary.isEmpty {
            findings.append(Finding(severity: .blocking, message: "제목이 빈 Jira 이슈 초안이 있습니다."))
        }

        // 검열 게이트를 미리 돌려 본다. 실제 게시 직전에 한 번 더 실행한다.
        let payload = bundle.page.storageBody()
            + bundle.includedIssues.flatMap(\.detailParagraphs).joined(separator: " ")
        let violations = PublishRedaction.audit(text: payload, evidence: evidence)
        for violation in violations {
            findings.append(
                Finding(severity: .blocking, message: "게시 금지 항목 포함(\(violation.kind.rawValue)): \(violation.detail)")
            )
        }

        return findings
    }

    public func canPublish(_ findings: [Finding]) -> Bool {
        !findings.contains { $0.severity == .blocking }
    }
}
