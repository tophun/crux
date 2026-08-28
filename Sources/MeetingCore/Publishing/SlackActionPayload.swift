import Foundation

/// Slack으로 보낼 액션 초안.
///
/// **구조적으로 전사·오디오·근거를 담을 수 없다.** 필드가 작업·담당자·기한과 회의 제목뿐이다.
/// Preview에서 `include`로 고른 액션만 들어가며, 회의 요약·결정·논의·타임스탬프는 넣지 않는다.
public struct SlackActionPayload: Hashable, Sendable, Codable {
    /// 채널 ID·이름 또는 DM(사용자 ID). 메시지 본문에는 넣지 않는다.
    public var destination: String
    public var meetingTitle: String
    public var actions: [Line]

    public struct Line: Hashable, Sendable, Codable {
        public var task: String
        public var assignee: String
        public var dueDate: String

        public init(task: String, assignee: String, dueDate: String) {
            self.task = task
            self.assignee = assignee
            self.dueDate = dueDate
        }
    }

    public init(destination: String, meetingTitle: String, actions: [Line]) {
        self.destination = destination
        self.meetingTitle = meetingTitle
        self.actions = actions
    }

    /// Preview에서 생성하기로 고른 액션만 담는다. Jira 상세 문단(회의 요약 등)은 복사하지 않는다.
    public static func make(from bundle: PublishBundle, destination: String) -> SlackActionPayload {
        SlackActionPayload(
            destination: destination,
            meetingTitle: bundle.page.title,
            actions: bundle.includedIssues.map { issue in
                Line(
                    task: issue.summary,
                    assignee: display(issue.assigneeQuery),
                    dueDate: display(issue.dueDate)
                )
            }
        )
    }

    public var normalizedDestination: String {
        var value = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") {
            value.removeFirst()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    /// Slack `chat.postMessage`에 넣는 본문. 액션 목록만 포함한다.
    public func messageText() -> String {
        var lines: [String] = []
        if meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("*액션 아이템*")
        } else {
            lines.append("*액션 아이템 — \(meetingTitle)*")
        }
        lines.append("")
        if actions.isEmpty {
            lines.append("보낼 액션 없음")
        } else {
            for action in actions {
                lines.append("• *\(action.task)*")
                lines.append("  담당: \(action.assignee) · 기한: \(action.dueDate)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func display(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? UnresolvedMarker.undetermined : trimmed
    }
}

/// Slack 보내기 버튼과 전송 사이의 확인 게이트.
///
/// 보내기를 눌러도 바로 전송하지 않는다. 확인 대화상자에서 한 번 더 승인한 뒤에만 `confirm()`이 참이 된다.
public struct SlackSendGate: Equatable, Sendable {
    public private(set) var awaitingConfirmation = false

    public init() {}

    /// 보내기 버튼을 눌렀을 때. 보낼 수 없으면 이유를 반환하고, 되면 확인 대기로 들어간다.
    public mutating func begin(destination: String, actionCount: Int) -> String? {
        if destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            awaitingConfirmation = false
            return "Slack 채널 또는 DM을 입력하세요."
        }
        if actionCount == 0 {
            awaitingConfirmation = false
            return "보낼 액션이 없습니다. Preview에서 생성할 항목을 선택하세요."
        }
        awaitingConfirmation = true
        return nil
    }

    /// 확인 대화상자에서 승인한 경우에만 `true`. 승인 없이는 전송하면 안 된다.
    public mutating func confirm() -> Bool {
        guard awaitingConfirmation else { return false }
        awaitingConfirmation = false
        return true
    }

    public mutating func cancel() {
        awaitingConfirmation = false
    }
}
