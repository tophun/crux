import Foundation

/// 캘린더와 실행 중인 앱으로 회의 시작을 감지한다.
///
/// 기본 동작은 **자동 녹음이 아니라 사용자 확인**이다. 정책은 순수 함수로 두어 테스트로 고정한다.
public struct MeetingDetectionPolicy: Sendable {
    public struct Configuration: Sendable {
        /// 일정에 알림이 없을 때 시작 몇 초 전부터 임박으로 볼지
        public var leadTime: TimeInterval
        /// 알림이 아주 이른 경우(예: 하루 전)에도 이 시간보다 먼저 띄우지는 않는다
        public var maximumLeadTime: TimeInterval
        /// 시작 후 몇 초까지 "방금 시작한 회의"로 볼지
        public var graceAfterStart: TimeInterval
        /// 종일 일정 제외
        public var excludeAllDay: Bool
        /// 취소된 일정 제외
        public var excludeCanceled: Bool
        /// 참석자가 이 수보다 적으면 제외 (혼자 있는 일정은 회의가 아니다)
        public var minimumAttendees: Int

        public init(
            leadTime: TimeInterval = 300,
            maximumLeadTime: TimeInterval = 3600,
            graceAfterStart: TimeInterval = 600,
            excludeAllDay: Bool = true,
            excludeCanceled: Bool = true,
            minimumAttendees: Int = 2
        ) {
            self.leadTime = leadTime
            self.maximumLeadTime = maximumLeadTime
            self.graceAfterStart = graceAfterStart
            self.excludeAllDay = excludeAllDay
            self.excludeCanceled = excludeCanceled
            self.minimumAttendees = minimumAttendees
        }
    }

    /// 감지 판정
    public enum Verdict: Equatable, Sendable {
        /// 표시할 것이 없음
        case idle
        /// 곧 시작하는 회의 — 캡슐에 임박 상태로 표시
        case imminent(event: CalendarEvent, secondsUntilStart: TimeInterval)
        /// 시작한 것으로 보이는 회의 — 사용자 확인을 요청
        case started(event: CalendarEvent, reason: StartReason)
        /// 캘린더에 없지만 회의 앱이 켜져 있음 — 사용자 확인을 요청
        case unscheduled(appName: String)

        public var event: CalendarEvent? {
            switch self {
            case .imminent(let event, _), .started(let event, _): event
            case .idle, .unscheduled: nil
            }
        }
    }

    public enum StartReason: String, Equatable, Sendable {
        /// 일정 시작 시각이 지났다
        case scheduleTime
        /// 일정 시각 + 회의 앱이 켜져 있다
        case scheduleTimeAndApp
    }

    public var configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// 이 일정을 시작 몇 초 전부터 띄울지.
    ///
    /// 캘린더에 설정한 알림이 있으면 **그 알림 시각에 맞춘다**. 사용자가 1분 전 알림을 걸었다면
    /// 캡슐도 1분 전에 뜬다. 알림이 없으면 기본값(5분 전)을 쓰고,
    /// 하루 전 같은 이른 알림은 최대치로 제한해 하루 종일 캡슐이 떠 있지 않게 한다.
    public func leadTime(for event: CalendarEvent) -> TimeInterval {
        guard let alarm = event.earliestAlarmLeadTime else { return configuration.leadTime }
        return min(alarm, configuration.maximumLeadTime)
    }

    /// 일정을 회의록 대상에서 뺀 이유. 왜 캡슐이 안 떴는지 설명할 수 있어야 한다.
    public enum ExclusionReason: String, Sendable {
        case allDay
        case canceled
        case tooFewAttendees
        case zeroDuration

        public var displayName: String {
            switch self {
            case .allDay: "종일 일정"
            case .canceled: "취소된 일정"
            case .tooFewAttendees: "참석자 부족"
            case .zeroDuration: "길이가 0"
            }
        }
    }

    /// 이 일정을 뺀다면 그 이유. 대상이면 nil.
    public func exclusionReason(for event: CalendarEvent) -> ExclusionReason? {
        if configuration.excludeAllDay, event.isAllDay { return .allDay }
        if configuration.excludeCanceled, event.status == .canceled { return .canceled }
        if event.attendees.count < configuration.minimumAttendees { return .tooFewAttendees }
        if event.duration <= 0 { return .zeroDuration }
        return nil
    }

    /// 회의록 대상이 될 수 있는 일정만 남긴다.
    public func eligibleEvents(_ events: [CalendarEvent]) -> [CalendarEvent] {
        events
            .filter { exclusionReason(for: $0) == nil }
            .sorted { $0.startDate < $1.startDate }
    }

    /// 뺀 일정과 그 이유. 진단 로그에 쓴다.
    public func exclusions(_ events: [CalendarEvent]) -> [(event: CalendarEvent, reason: ExclusionReason)] {
        events.compactMap { event in
            exclusionReason(for: event).map { (event: event, reason: $0) }
        }
    }

    /// 지금 무엇을 표시할지 결정한다.
    /// - Parameters:
    ///   - notifiedEventIds: 이미 알림을 보여 준 이벤트. 같은 회의에 두 번 묻지 않는다.
    ///   - conferenceApps: 실행 중인 회의 앱
    public func decide(
        events: [CalendarEvent],
        now: Date,
        notifiedEventIds: Set<String>,
        conferenceApps: [ConferenceAppSignal] = []
    ) -> Verdict {
        let eligible = eligibleEvents(events).filter { !notifiedEventIds.contains($0.id) }

        // 1. 이미 시작한(또는 방금 시작한) 회의
        let started = eligible.filter { event in
            let secondsSinceStart = now.timeIntervalSince(event.startDate)
            return secondsSinceStart >= 0
                && secondsSinceStart <= configuration.graceAfterStart
                && now < event.endDate
        }
        if let event = started.first {
            let appActive = !conferenceApps.isEmpty
            return .started(event: event, reason: appActive ? .scheduleTimeAndApp : .scheduleTime)
        }

        // 2. 곧 시작하는 회의
        let imminent = eligible.filter { event in
            let secondsUntilStart = event.startDate.timeIntervalSince(now)
            return secondsUntilStart > 0 && secondsUntilStart <= leadTime(for: event)
        }
        if let event = imminent.first {
            return .imminent(event: event, secondsUntilStart: event.startDate.timeIntervalSince(now))
        }

        // 3. 일정에 없지만 회의 앱이 켜져 있는 경우
        if let app = conferenceApps.first(where: { $0.usesAudio }) {
            return .unscheduled(appName: app.appName)
        }

        return .idle
    }

    /// 캡슐에 띄울 확인 문구. 회의 제목을 그대로 쓰고 문구를 만들어내지 않는다.
    public func confirmationMessage(for verdict: Verdict) -> String? {
        switch verdict {
        case .idle:
            return nil
        case .imminent(let event, let seconds):
            let minutes = max(1, Int((seconds / 60).rounded()))
            return "\(event.title) 시작 \(minutes)분 전입니다."
        case .started(let event, _):
            return "\(event.title) 회의 중이신가요? 녹음을 진행하시겠습니까?"
        case .unscheduled(let appName):
            return "\(appName)에서 회의 중이신가요? 녹음을 진행하시겠습니까?"
        }
    }
}

/// 중복 알림 방지를 위한 저장소. 앱을 다시 켜도 같은 회의를 두 번 묻지 않도록 영속화한다.
public protocol NotifiedEventStore: Sendable {
    func notifiedEventIds() throws -> Set<String>
    func markNotified(eventId: String, at date: Date) throws
    /// 오래된 기록 정리
    func pruneNotified(before date: Date) throws
}
