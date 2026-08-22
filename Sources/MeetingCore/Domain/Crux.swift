import Foundation

/// Crux 상태(요구사항 3).
///
/// 회의 임박 → 회의 시작 감지 → 녹음 중 → 회의록 생성 중 → Preview 준비 완료 → 게시 완료
public enum CruxState: Equatable, Sendable {
    case hidden
    /// 회의 임박
    case imminent(title: String, minutesUntilStart: Int)
    /// 회의 시작 감지 — 사용자 확인 대기
    case detected(title: String?, message: String)
    /// 회의록 녹음 중
    case recording(elapsed: TimeInterval, paused: Bool)
    /// 회의록 생성 중
    case generating(fraction: Double, message: String)
    /// Preview 준비 완료
    case previewReady(meetingId: UUID, actionItemCount: Int)
    /// 게시 완료
    case published(confluencePageTitle: String?, jiraIssueCount: Int)
    /// 실패
    case failed(message: String)

    /// 캡슐에 보이는 짧은 문구
    public var capsuleText: String {
        switch self {
        case .hidden:
            ""
        case let .imminent(title, minutes):
            "\(title) \(minutes)분 전"
        case .detected:
            "회의가 시작된 것 같습니다"
        case let .recording(elapsed, paused):
            paused ? "일시정지 · \(Self.clock(elapsed))" : "녹음 중 · \(Self.clock(elapsed))"
        case .generating:
            "회의록 작성 중"
        case .previewReady:
            "회의록 준비 완료"
        case let .published(_, issueCount):
            issueCount > 0
                ? "Confluence 게시 · Jira 이슈 \(issueCount)개 생성"
                : "Confluence 게시 완료"
        case .failed:
            "처리 실패"
        }
    }

    /// 케이스 종류를 나타내는 값. 녹음 시간처럼 매초 바뀌는 값과 무관하다.
    ///
    /// UI가 "상태가 진짜로 넘어갔는지"를 볼 때 쓴다. `state` 자체를 보면 초 단위 갱신에도 반응해 버린다.
    public var kindId: String {
        switch self {
        case .hidden: "hidden"
        case .imminent: "imminent"
        case .detected: "detected"
        case let .recording(_, paused): paused ? "recording.paused" : "recording"
        case .generating: "generating"
        case .previewReady: "previewReady"
        case .published: "published"
        case .failed: "failed"
        }
    }

    /// 캡슐 **좌측**에 두는 상태 문구. 시간·진행률 같은 수치는 `trailingText`로 뺀다.
    public var statusText: String {
        switch self {
        case .hidden:
            ""
        case let .imminent(title, _):
            title
        case .detected:
            "회의가 시작된 것 같습니다"
        case let .recording(_, paused):
            paused ? "일시정지" : "녹음 중"
        case .generating:
            "회의록 작성 중"
        case .previewReady:
            "회의록 준비 완료"
        case .published:
            "게시 완료"
        case .failed:
            "처리 실패"
        }
    }

    /// 캡슐 **우측**에 두는 수치. 녹음 중에는 경과 시간이다.
    public var trailingText: String? {
        switch self {
        case .hidden, .detected, .failed:
            nil
        case let .imminent(_, minutes):
            "\(minutes)분 전"
        case let .recording(elapsed, _):
            Self.clock(elapsed)
        case let .generating(fraction, _):
            "\(Int((fraction * 100).rounded()))%"
        case let .previewReady(_, count):
            count > 0 ? "액션 \(count)개" : nil
        case let .published(_, issueCount):
            issueCount > 0 ? "이슈 \(issueCount)개" : nil
        }
    }

    /// 좌측 아이콘. 녹음 중에는 점(원)을 따로 그리므로 nil이다.
    public var symbolName: String? {
        switch self {
        case .hidden: nil
        case .imminent, .detected: "calendar.badge.clock"
        case .recording: nil
        case .generating: "waveform"
        case .previewReady: "doc.text.magnifyingglass"
        case .published: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    /// 캡슐 안에 함께 두는 주 동작 버튼 제목
    public var primaryActionTitle: String? {
        switch self {
        case .hidden, .generating: nil
        case .imminent: "회의록 준비"
        case .detected: "회의록 시작"
        case let .recording(_, paused): paused ? "재개" : "종료"
        case .previewReady: "검토하기"
        case .published: "열기"
        case .failed: "다시 시도"
        }
    }

    public var isVisible: Bool {
        self != .hidden
    }

    /// 클릭하면 상세 패널로 확장할 수 있는 상태인지
    public var isExpandable: Bool {
        switch self {
        case .hidden: false
        default: true
        }
    }

    /// 녹음 중임을 명확히 알려야 하는 상태 (§11 개인정보 UX)
    public var showsRecordingIndicator: Bool {
        if case .recording = self {
            return true
        }
        return false
    }

    public static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let secs = total % 60
        let hours = minutes / 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes % 60, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

/// 상태 전이를 일으키는 사건.
public enum CruxEvent: Equatable, Sendable {
    case detection(MeetingDetectionPolicy.Verdict, message: String?)
    /// 사용자가 회의록 시작을 승인
    case userStartedMeeting
    case recordingTicked(elapsed: TimeInterval)
    case recordingPaused
    case recordingResumed
    /// 녹음 종료 → 처리 시작
    case recordingStopped
    case processingProgress(fraction: Double, message: String)
    case previewReady(meetingId: UUID, actionItemCount: Int)
    case published(confluencePageTitle: String?, jiraIssueCount: Int)
    case failed(message: String)
    /// 사용자가 캡슐을 닫음 (같은 회의는 다시 묻지 않는다)
    case dismissed
    case reset
}

/// Crux 상태 머신. UI와 분리해 두어 전이 규칙을 테스트로 고정한다.
public struct CruxMachine: Sendable {
    public private(set) var state: CruxState
    /// 사용자가 닫은 이벤트. 같은 회의에 다시 묻지 않기 위해 기록한다.
    public private(set) var dismissedEventIds: Set<String>
    /// 현재 진행 중인 회의의 캘린더 이벤트
    public private(set) var activeEvent: CalendarEvent?

    public init(
        state: CruxState = .hidden,
        dismissedEventIds: Set<String> = [],
        activeEvent: CalendarEvent? = nil
    ) {
        self.state = state
        self.dismissedEventIds = dismissedEventIds
        self.activeEvent = activeEvent
    }

    @discardableResult
    public mutating func apply(_ event: CruxEvent) -> CruxState {
        switch event {
        case let .detection(verdict, message):
            // 녹음·처리 중에는 감지 결과로 상태를 덮지 않는다.
            switch state {
            case .recording, .generating, .previewReady, .published:
                break
            default:
                apply(detection: verdict, message: message)
            }

        case .userStartedMeeting:
            state = .recording(elapsed: 0, paused: false)

        case let .recordingTicked(elapsed):
            if case let .recording(_, paused) = state {
                state = .recording(elapsed: elapsed, paused: paused)
            }

        case .recordingPaused:
            if case let .recording(elapsed, _) = state {
                state = .recording(elapsed: elapsed, paused: true)
            }

        case .recordingResumed:
            if case let .recording(elapsed, _) = state {
                state = .recording(elapsed: elapsed, paused: false)
            }

        case .recordingStopped:
            state = .generating(fraction: 0, message: "회의록 작성 중")

        case let .processingProgress(fraction, message):
            state = .generating(fraction: min(1, max(0, fraction)), message: message)

        case let .previewReady(meetingId, count):
            state = .previewReady(meetingId: meetingId, actionItemCount: count)

        case let .published(title, issueCount):
            state = .published(confluencePageTitle: title, jiraIssueCount: issueCount)

        case let .failed(message):
            state = .failed(message: message)

        case .dismissed:
            if let id = activeEvent?.id {
                dismissedEventIds.insert(id)
            }
            activeEvent = nil
            state = .hidden

        case .reset:
            activeEvent = nil
            state = .hidden
        }
        return state
    }

    private mutating func apply(detection verdict: MeetingDetectionPolicy.Verdict, message: String?) {
        if let id = verdict.event?.id, dismissedEventIds.contains(id) {
            state = .hidden
            return
        }
        switch verdict {
        case .idle:
            activeEvent = nil
            state = .hidden
        case let .imminent(event, seconds):
            activeEvent = event
            state = .imminent(title: event.title, minutesUntilStart: max(1, Int((seconds / 60).rounded())))
        case let .started(event, _):
            activeEvent = event
            state = .detected(
                title: event.title,
                message: message ?? "\(event.title) 회의 중이신가요? 녹음을 진행하시겠습니까?"
            )
        case let .unscheduled(appName):
            activeEvent = nil
            state = .detected(
                title: nil,
                message: message ?? "\(appName)에서 회의 중이신가요? 녹음을 진행하시겠습니까?"
            )
        }
    }
}
