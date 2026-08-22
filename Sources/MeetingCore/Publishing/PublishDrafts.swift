import Foundation

/// Confluence에 게시할 회의록 초안.
///
/// **구조적으로 근거를 담을 수 없다.** 타임스탬프·전사 원문·세그먼트 ID·내부 ID를 넣을 필드가 없다.
/// 이것이 "전체 녹취록과 음성 파일은 Atlassian으로 전송하지 않는다"를 지키는 방식이다.
public struct ConfluencePageDraft: Hashable, Sendable, Codable {
    /// 회의 제목
    public var title: String
    /// 회의 날짜 (Google Calendar 이벤트 정보를 우선 사용)
    public var meetingDate: String
    /// 참석자 (Calendar 참석자 정보를 우선 사용하며 임의로 추가하지 않는다)
    public var attendees: [String]
    public var summary: String
    public var decisions: [String]
    public var actionItems: [ActionLine]
    /// 논의 내용 — 주제별 요약이다. 전사 원문이 아니다.
    public var discussion: [DiscussionLine]
    public var risks: [String]
    public var openQuestions: [String]
    /// 함께 생성된 Jira 이슈 키 (게시 후 채워 상호 링크에 사용)
    public var linkedIssueKeys: [String]

    public struct ActionLine: Hashable, Sendable, Codable {
        public var task: String
        public var assignee: String
        public var dueDate: String

        public init(task: String, assignee: String, dueDate: String) {
            self.task = task
            self.assignee = assignee
            self.dueDate = dueDate
        }
    }

    public struct DiscussionLine: Hashable, Sendable, Codable {
        public var topic: String
        public var detail: String

        public init(topic: String, detail: String) {
            self.topic = topic
            self.detail = detail
        }
    }

    public init(
        title: String,
        meetingDate: String,
        attendees: [String] = [],
        summary: String = "",
        decisions: [String] = [],
        actionItems: [ActionLine] = [],
        discussion: [DiscussionLine] = [],
        risks: [String] = [],
        openQuestions: [String] = [],
        linkedIssueKeys: [String] = []
    ) {
        self.title = title
        self.meetingDate = meetingDate
        self.attendees = attendees
        self.summary = summary
        self.decisions = decisions
        self.actionItems = actionItems
        self.discussion = discussion
        self.risks = risks
        self.openQuestions = openQuestions
        self.linkedIssueKeys = linkedIssueKeys
    }

    /// Confluence storage format(HTML) 본문.
    ///
    /// 순서: 회의 제목 → 날짜 → 참석자 → 회의 요약 → 주요 결정사항 → 액션 아이템
    ///       → 논의 내용 → 리스크 및 미해결 질문
    /// 날짜와 참석자를 문서 상단에 가장 먼저 노출한다.
    public func storageBody() -> String {
        var html = ""

        html += "<p><strong>날짜</strong>: \(Self.escape(meetingDate))</p>"
        let attendeeText = attendees.isEmpty ? "캘린더 참석자 정보 없음" : attendees.joined(separator: ", ")
        html += "<p><strong>참석자</strong>: \(Self.escape(attendeeText))</p>"

        html += "<h2>회의 요약</h2>"
        html += "<p>\(Self.escape(summary.isEmpty ? "요약 없음" : summary))</p>"

        html += "<h2>주요 결정사항</h2>"
        html += Self.list(decisions, empty: "확정된 결정사항 없음")

        html += "<h2>액션 아이템</h2>"
        if actionItems.isEmpty {
            html += "<p>없음</p>"
        } else {
            html += "<table><tbody><tr><th>작업</th><th>담당자</th><th>기한</th></tr>"
            for item in actionItems {
                html += "<tr><td>\(Self.escape(item.task))</td>"
                html += "<td>\(Self.escape(item.assignee))</td>"
                html += "<td>\(Self.escape(item.dueDate))</td></tr>"
            }
            html += "</tbody></table>"
        }

        html += "<h2>논의 내용</h2>"
        if discussion.isEmpty {
            html += "<p>기록된 논의 내용 없음</p>"
        } else {
            html += "<ul>"
            for line in discussion {
                let detail = line.detail.isEmpty ? "" : ": \(Self.escape(line.detail))"
                html += "<li><strong>\(Self.escape(line.topic))</strong>\(detail)</li>"
            }
            html += "</ul>"
        }

        html += "<h2>리스크 및 미해결 질문</h2>"
        if risks.isEmpty, openQuestions.isEmpty {
            html += "<p>없음</p>"
        } else {
            if !risks.isEmpty {
                html += "<h3>리스크</h3>" + Self.list(risks, empty: "없음")
            }
            if !openQuestions.isEmpty {
                html += "<h3>미해결 질문</h3>" + Self.list(openQuestions, empty: "없음")
            }
        }

        if !linkedIssueKeys.isEmpty {
            html += "<h2>연결된 Jira 이슈</h2>"
            html += Self.list(linkedIssueKeys, empty: "없음")
        }

        return html
    }

    static func list(_ items: [String], empty: String) -> String {
        guard !items.isEmpty else { return "<p>\(escape(empty))</p>" }
        return "<ul>" + items.map { "<li>\(escape($0))</li>" }.joined() + "</ul>"
    }

    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Jira 이슈 초안. 사용자가 Preview Viewer에서 검토·수정한 뒤 생성한다.
public struct JiraIssueDraft: Identifiable, Hashable, Sendable, Codable {
    /// 로컬 초안 식별자. 게시되지 않는다.
    public var id: UUID
    /// 근거 파일과 연결되는 내부 contentId. 게시되지 않는다.
    public var contentId: String
    public var summary: String
    /// 상세 내용 문단. 타임스탬프와 전사 원문은 넣지 않는다.
    public var detailParagraphs: [String]
    public var projectKey: String
    public var issueTypeName: String
    /// 담당자 조회용 값 (이메일 또는 표시 이름). 근거가 없으면 nil이다.
    public var assigneeQuery: String?
    /// YYYY-MM-DD. 원문에서 확정되지 않았으면 nil이다.
    public var dueDate: String?
    public var priorityName: String?
    /// 생성 여부 — 사용자가 끌 수 있다.
    public var include: Bool

    public init(
        id: UUID = UUID(),
        contentId: String,
        summary: String,
        detailParagraphs: [String] = [],
        projectKey: String,
        issueTypeName: String = "Task",
        assigneeQuery: String? = nil,
        dueDate: String? = nil,
        priorityName: String? = nil,
        include: Bool = true
    ) {
        self.id = id
        self.contentId = contentId
        self.summary = summary
        self.detailParagraphs = detailParagraphs
        self.projectKey = projectKey
        self.issueTypeName = issueTypeName
        self.assigneeQuery = assigneeQuery
        self.dueDate = dueDate
        self.priorityName = priorityName
        self.include = include
    }

    public static let selectableIssueTypes = ["Task", "Bug", "Story"]
    public static let selectablePriorities = ["Highest", "High", "Medium", "Low", "Lowest"]

    /// Jira v3 description은 ADF(Atlas Document Format) JSON이다.
    public func descriptionADF() -> [String: Any] {
        let paragraphs = detailParagraphs.filter { !$0.isEmpty }
        let content: [[String: Any]] = (paragraphs.isEmpty ? ["회의록에서 생성된 액션 아이템입니다."] : paragraphs)
            .map { text in
                [
                    "type": "paragraph",
                    "content": [["type": "text", "text": text]]
                ]
            }
        return ["type": "doc", "version": 1, "content": content]
    }
}

/// 게시 묶음. Preview와 실제 게시가 같은 데이터에서 렌더링된다(요구사항 4).
public struct PublishBundle: Hashable, Sendable, Codable {
    public var meetingId: UUID
    public var page: ConfluencePageDraft
    public var issues: [JiraIssueDraft]
    /// 게시 대상 Confluence Space 키
    public var spaceKey: String
    /// 게시 대상 Jira Project 키
    public var projectKey: String

    public init(
        meetingId: UUID,
        page: ConfluencePageDraft,
        issues: [JiraIssueDraft],
        spaceKey: String,
        projectKey: String
    ) {
        self.meetingId = meetingId
        self.page = page
        self.issues = issues
        self.spaceKey = spaceKey
        self.projectKey = projectKey
    }

    public var includedIssues: [JiraIssueDraft] {
        issues.filter(\.include)
    }
}
