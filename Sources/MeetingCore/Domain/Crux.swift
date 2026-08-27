import Foundation

/// 노치 셸프의 표시 상태.
///
/// `preview`는 포인터가 셸프 위에 있어 잠깐 펼쳐진 상태이고, `pinned`는
/// 사용자가 클릭해 고정한 상태다. 호버와 고정 여부를 두 개의 Bool로 조합하면
/// 상태 전환 때 잠깐 잘못된 조합이 보일 수 있으므로 화면에서는 이 값을 하나만 쓴다.
public enum CruxExpansionMode: Equatable, Sendable {
    case collapsed
    case preview
    case pinned

    public var isExpanded: Bool {
        self != .collapsed
    }

    public var isPinned: Bool {
        self == .pinned
    }

    public var isPreview: Bool {
        self == .preview
    }

    /// 기존 호버/고정 입력을 한 가지 표시 상태로 정규화한다.
    public static func resolve(isHovering: Bool, isPinned: Bool) -> Self {
        if isPinned {
            return .pinned
        }
        return isHovering ? .preview : .collapsed
    }

    /// 포인터가 들어오거나 나갈 때의 표시 상태다. 고정된 셸프는 포인터가
    /// 나가도 열린 채로 유지한다.
    public func handlingHover(_ hovering: Bool) -> Self {
        switch (self, hovering) {
        case (.pinned, _):
            return .pinned
        case (_, true):
            return .preview
        case (_, false):
            return .collapsed
        }
    }

    /// 셸프를 클릭했을 때 고정을 켜거나 끈다.
    public func togglingPin() -> Self {
        isPinned ? .collapsed : .pinned
    }
}

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
    ///
    /// 펼쳤을 때 쓴다. 접힌 노치에는 `compactStatusText`를 쓴다.
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

    /// 접힌 노치 왼쪽 날개에 넣는 짧은 문구. 말줄임 없이 항상 들어가야 한다.
    ///
    /// 회의 제목·긴 확인 문장은 접힌 상태에서 쓰지 않는다. 펼치거나 상세에서 보여 준다.
    public var compactStatusText: String {
        switch self {
        case .hidden:
            ""
        case .imminent:
            "곧 시작"
        case .detected:
            "회의 시작"
        case let .recording(_, paused):
            paused ? "일시정지" : "녹음 중"
        case .generating:
            "작성 중"
        case .previewReady:
            "준비 완료"
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

/// 셸프에 표시할 수 있는 사용자 동작.
///
/// 도메인 상태(`CruxState`)와 화면 문구·버튼 매핑을 분리하면 상태 머신은
/// 그대로 둔 채 노치 셸프와 다른 화면에서 같은 의미를 재사용할 수 있다.
public enum CruxShelfAction: String, Equatable, Sendable {
    case prepareMeeting
    case startMeeting
    case pauseRecording
    case resumeRecording
    case stopRecording
    case cancelProcessing
    case review
    case open
    case retry
    case dismiss

    public var title: String {
        switch self {
        case .prepareMeeting: "회의록 준비"
        case .startMeeting: "회의록 시작"
        case .pauseRecording: "일시정지"
        case .resumeRecording: "재개"
        case .stopRecording: "종료"
        case .cancelProcessing: "생성 취소"
        case .review: "검토하기"
        case .open: "열기"
        case .retry: "다시 시도"
        case .dismiss: "닫기"
        }
    }

    public var accessibilityLabel: String {
        switch self {
        case .prepareMeeting: "회의록 준비"
        case .startMeeting: "회의록 시작"
        case .pauseRecording: "녹음 일시정지"
        case .resumeRecording: "녹음 재개"
        case .stopRecording: "녹음 종료"
        case .cancelProcessing: "회의록 생성 취소"
        case .review: "회의록 검토"
        case .open: "게시된 회의록 열기"
        case .retry: "다시 시도"
        case .dismiss: "닫기"
        }
    }
}

/// 한 상태를 셸프의 제목·보조 문구·진행 정보·동작으로 변환한 표현 모델.
///
/// 이 타입은 UI 프레임워크에 의존하지 않아 상태별 표시 규칙을 단위 테스트할 수
/// 있고, 화면은 이 모델을 그리기만 한다.
public struct CruxPresentationModel: Equatable, Sendable {
    public let stateKind: String
    public let compactTitle: String
    public let title: String?
    public let detailText: String?
    public let trailingText: String?
    public let symbolName: String?
    public let showsRecordingIndicator: Bool
    public let elapsed: TimeInterval?
    public let progressFraction: Double?
    public let primaryAction: CruxShelfAction?
    public let secondaryActions: [CruxShelfAction]
    public let accessibilityLabel: String

    public var kindId: String { stateKind }
    public var statusText: String { title ?? "" }
    public var compactStatusText: String { compactTitle }
    public var detailMessage: String? { detailText }
    public var progress: Double? { progressFraction }
    public var primaryActionTitle: String? { primaryAction?.title }

    public init(state: CruxState, detailMessage: String? = nil) {
        stateKind = state.kindId
        compactTitle = state.compactStatusText
        trailingText = state.trailingText
        symbolName = state.symbolName
        showsRecordingIndicator = state.showsRecordingIndicator

        switch state {
        case .hidden:
            title = nil
            detailText = nil
            elapsed = nil
            progressFraction = nil
            primaryAction = nil
            secondaryActions = []

        case let .imminent(meetingTitle, minutes):
            title = meetingTitle
            detailText = "\(minutes)분 뒤 시작합니다."
            elapsed = nil
            progressFraction = nil
            primaryAction = .prepareMeeting
            secondaryActions = [.dismiss]

        case let .detected(meetingTitle, message):
            title = meetingTitle ?? "회의 감지"
            detailText = message
            elapsed = nil
            progressFraction = nil
            primaryAction = .startMeeting
            secondaryActions = [.dismiss]

        case let .recording(seconds, paused):
            title = paused ? "녹음 일시정지" : "녹음 중"
            detailText = "마이크와 시스템 오디오는 이 기기에만 저장됩니다."
            elapsed = max(0, seconds)
            progressFraction = nil
            primaryAction = paused ? .resumeRecording : .stopRecording
            secondaryActions = paused ? [.resumeRecording, .stopRecording] : [.pauseRecording, .stopRecording]

        case let .generating(fraction, message):
            title = "회의록 작성 중"
            detailText = detailMessage ?? message
            elapsed = nil
            progressFraction = min(1, max(0, fraction))
            primaryAction = nil
            secondaryActions = [.cancelProcessing]

        case let .previewReady(_, count):
            title = "회의록 준비 완료"
            detailText = count > 0
                ? "액션 아이템 \(count)개를 검토할 수 있습니다."
                : "회의록을 검토할 수 있습니다."
            elapsed = nil
            progressFraction = nil
            primaryAction = .review
            secondaryActions = [.dismiss]

        case let .published(pageTitle, issueCount):
            title = pageTitle ?? "게시 완료"
            detailText = issueCount > 0
                ? "Jira 이슈 \(issueCount)개 생성"
                : "게시를 마쳤습니다."
            elapsed = nil
            progressFraction = nil
            primaryAction = .open
            secondaryActions = [.dismiss]

        case let .failed(message):
            title = "처리 실패"
            detailText = message
            elapsed = nil
            progressFraction = nil
            primaryAction = .retry
            secondaryActions = [.dismiss]
        }

        accessibilityLabel = Self.makeAccessibilityLabel(
            state: state,
            title: title,
            elapsed: elapsed,
            progressFraction: progressFraction,
            primaryAction: primaryAction,
            secondaryActions: secondaryActions
        )
    }

    /// `CruxState`에서 바로 표현 모델을 얻는다.
    public static func make(state: CruxState, detailMessage: String? = nil) -> Self {
        Self(state: state, detailMessage: detailMessage)
    }

    private static func makeAccessibilityLabel(
        state: CruxState,
        title: String?,
        elapsed: TimeInterval?,
        progressFraction: Double?,
        primaryAction: CruxShelfAction?,
        secondaryActions: [CruxShelfAction]
    ) -> String {
        guard state.isVisible else { return "Crux 숨김" }

        var parts = [title ?? state.statusText]
        if let elapsed {
            parts.append("경과 시간 \(CruxState.clock(elapsed))")
        }
        if let progressFraction {
            parts.append("진행률 \(Int((progressFraction * 100).rounded()))%")
        }
        let actions = ([primaryAction].compactMap { $0 } + secondaryActions)
            .map(\.accessibilityLabel)
        if !actions.isEmpty {
            parts.append("가능한 동작: \(actions.joined(separator: ", "))")
        }
        return parts.joined(separator: ". ")
    }
}

/// 표현 모델의 짧은 이름도 제공해 화면 코드와 테스트에서 읽기 쉽게 한다.
public typealias CruxShelfPresentation = CruxPresentationModel
public typealias CruxPresentation = CruxPresentationModel

public extension CruxState {
    /// 기본 상태 문구로 만든 셸프 표현 모델.
    var presentation: CruxPresentationModel {
        CruxPresentationModel(state: self)
    }

    /// 처리 단계 메시지를 UI에서 덮어써야 할 때 사용하는 표현 모델.
    func presentation(detailMessage: String?) -> CruxPresentationModel {
        CruxPresentationModel(state: self, detailMessage: detailMessage)
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
