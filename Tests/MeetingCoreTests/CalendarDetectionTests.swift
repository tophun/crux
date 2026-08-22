import Foundation
import Testing
@testable import MeetingCore

extension Fixtures {
    static let now = Date(timeIntervalSince1970: 1_772_000_000)  // 고정 기준 시각

    static func event(
        id: String = "evt-1",
        title: String = "주간 유저성장 회의",
        startOffset: TimeInterval,
        duration: TimeInterval = 3600,
        isAllDay: Bool = false,
        status: CalendarEventStatus = .confirmed,
        attendeeCount: Int = 3,
        conferenceURL: URL? = URL(string: "https://meet.google.com/abc-defg-hij")
    ) -> CalendarEvent {
        let attendees = (0..<attendeeCount).map { index in
            EventAttendee(
                name: index == 0 ? "김민수" : "참석자\(index)",
                email: "user\(index)@example.com",
                isOrganizer: index == 0,
                isCurrentUser: index == 1
            )
        }
        let start = now.addingTimeInterval(startOffset)
        return CalendarEvent(
            id: id,
            title: title,
            startDate: start,
            endDate: start.addingTimeInterval(duration),
            isAllDay: isAllDay,
            status: status,
            attendees: attendees,
            conferenceURL: conferenceURL,
            organizer: attendees.first
        )
    }
}

@Suite("회의 감지 정책")
struct MeetingDetectionPolicyTests {
    let policy = MeetingDetectionPolicy()

    @Test("종일·취소·참석자 없는 일정은 제외한다")
    func filtersIneligibleEvents() {
        let events = [
            Fixtures.event(id: "ok", startOffset: 60),
            Fixtures.event(id: "allday", startOffset: 60, isAllDay: true),
            Fixtures.event(id: "canceled", startOffset: 60, status: .canceled),
            Fixtures.event(id: "solo", startOffset: 60, attendeeCount: 1),
        ]
        let eligible = policy.eligibleEvents(events).map(\.id)
        #expect(eligible == ["ok"])
    }

    @Test("시작 5분 전에는 임박 상태를 알린다")
    func detectsImminent() {
        let event = Fixtures.event(startOffset: 180)
        let verdict = policy.decide(events: [event], now: Fixtures.now, notifiedEventIds: [])
        guard case .imminent(let detected, let seconds) = verdict else {
            Issue.record("임박 판정이 아님: \(verdict)")
            return
        }
        #expect(detected.id == event.id)
        #expect(seconds == 180)
        #expect(policy.confirmationMessage(for: verdict)?.contains("3분 전") == true)
    }

    @Test("시작 시각이 지나면 사용자 확인을 요청한다")
    func detectsStarted() {
        let event = Fixtures.event(startOffset: -120)
        let verdict = policy.decide(events: [event], now: Fixtures.now, notifiedEventIds: [])
        guard case .started(let detected, let reason) = verdict else {
            Issue.record("시작 판정이 아님: \(verdict)")
            return
        }
        #expect(detected.id == event.id)
        #expect(reason == .scheduleTime)
        let message = policy.confirmationMessage(for: verdict)
        #expect(message == "주간 유저성장 회의 회의 중이신가요? 녹음을 진행하시겠습니까?")
    }

    @Test("회의 앱이 함께 켜져 있으면 근거를 함께 기록한다")
    func detectsStartedWithApp() {
        let event = Fixtures.event(startOffset: -60)
        let verdict = policy.decide(
            events: [event],
            now: Fixtures.now,
            notifiedEventIds: [],
            conferenceApps: [ConferenceAppSignal(appName: "Zoom", isFrontmost: true, usesAudio: true)]
        )
        guard case .started(_, let reason) = verdict else {
            Issue.record("시작 판정이 아님")
            return
        }
        #expect(reason == .scheduleTimeAndApp)
    }

    @Test("이미 알린 회의는 다시 묻지 않는다")
    func doesNotRepeatNotification() {
        let event = Fixtures.event(startOffset: -60)
        let verdict = policy.decide(
            events: [event],
            now: Fixtures.now,
            notifiedEventIds: [event.id]
        )
        #expect(verdict == .idle)
    }

    @Test("일정이 없어도 오디오를 쓰는 회의 앱이 있으면 확인을 요청한다")
    func detectsUnscheduledMeeting() {
        let verdict = policy.decide(
            events: [],
            now: Fixtures.now,
            notifiedEventIds: [],
            conferenceApps: [ConferenceAppSignal(appName: "Zoom", usesAudio: true)]
        )
        #expect(verdict == .unscheduled(appName: "Zoom"))
        #expect(policy.confirmationMessage(for: verdict)?.contains("녹음을 진행하시겠습니까?") == true)
    }

    @Test("회의 앱이 오디오를 쓰지 않으면 알리지 않는다")
    func ignoresIdleApp() {
        let verdict = policy.decide(
            events: [],
            now: Fixtures.now,
            notifiedEventIds: [],
            conferenceApps: [ConferenceAppSignal(appName: "Slack", usesAudio: false)]
        )
        #expect(verdict == .idle)
    }

    @Test("참석자는 주최자를 먼저 두고 캘린더에 있는 사람만 넣는다")
    func attendeeOrdering() {
        let event = Fixtures.event(startOffset: 0, attendeeCount: 3)
        #expect(event.attendeeDisplayNames.first == "김민수")
        #expect(event.attendeeDisplayNames.count == 3)
    }
}

@Suite("Live Capsule 상태 머신")
struct LiveCapsuleMachineTests {
    @Test("감지 → 녹음 → 생성 → Preview → 게시 순서로 전이한다")
    func fullLifecycle() {
        var machine = LiveCapsuleMachine()
        let event = Fixtures.event(startOffset: -60)

        machine.apply(.detection(.started(event: event, reason: .scheduleTime), message: nil))
        #expect(machine.state.capsuleText == "회의가 시작된 것 같습니다")
        #expect(machine.state.primaryActionTitle == "회의록 시작")

        machine.apply(.userStartedMeeting)
        machine.apply(.recordingTicked(elapsed: 754))
        #expect(machine.state.capsuleText == "녹음 중 · 12:34")
        #expect(machine.state.showsRecordingIndicator)

        machine.apply(.recordingPaused)
        #expect(machine.state.capsuleText.hasPrefix("일시정지"))
        machine.apply(.recordingResumed)

        machine.apply(.recordingStopped)
        #expect(machine.state.capsuleText == "회의록 작성 중")

        machine.apply(.processingProgress(fraction: 0.5, message: "재검토 2/5 항목"))
        if case .generating(let fraction, _) = machine.state {
            #expect(fraction == 0.5)
        } else {
            Issue.record("생성 상태가 아님")
        }

        let meetingId = UUID()
        machine.apply(.previewReady(meetingId: meetingId, actionItemCount: 3))
        #expect(machine.state.capsuleText == "회의록 준비 완료")
        #expect(machine.state.primaryActionTitle == "검토하기")

        machine.apply(.published(confluencePageTitle: "주간 회의", jiraIssueCount: 3))
        #expect(machine.state.capsuleText == "Confluence 게시 · Jira 이슈 3개 생성")
    }

    @Test("사용자가 닫은 회의는 다시 표시하지 않는다")
    func respectsDismissal() {
        var machine = LiveCapsuleMachine()
        let event = Fixtures.event(startOffset: -60)
        machine.apply(.detection(.started(event: event, reason: .scheduleTime), message: nil))
        machine.apply(.dismissed)
        #expect(machine.state == .hidden)
        #expect(machine.dismissedEventIds.contains(event.id))

        machine.apply(.detection(.started(event: event, reason: .scheduleTime), message: nil))
        #expect(machine.state == .hidden)
    }

    @Test("녹음·처리 중에는 감지 결과로 상태를 덮지 않는다")
    func detectionDoesNotOverrideRecording() {
        var machine = LiveCapsuleMachine()
        machine.apply(.userStartedMeeting)
        machine.apply(.recordingTicked(elapsed: 30))
        machine.apply(.detection(.imminent(event: Fixtures.event(startOffset: 120), secondsUntilStart: 120), message: nil))
        #expect(machine.state == .recording(elapsed: 30, paused: false))
    }

    @Test("임박 상태는 회의 제목과 남은 시간을 보여준다")
    func imminentText() {
        var machine = LiveCapsuleMachine()
        machine.apply(.detection(.imminent(event: Fixtures.event(startOffset: 300), secondsUntilStart: 300), message: nil))
        #expect(machine.state.capsuleText == "주간 유저성장 회의 5분 전")
    }

    @Test("숨은 상태는 확장할 수 없고 표시되지 않는다")
    func hiddenState() {
        let machine = LiveCapsuleMachine()
        #expect(!machine.state.isVisible)
        #expect(!machine.state.isExpandable)
    }
}

@Suite("노치 일체형 배치")
struct NotchMetricsTests {
    /// 14인치 MacBook Pro 내장 화면 근사값
    func notchedScreen() -> NotchMetrics {
        NotchMetrics(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            notchHeight: 37,
            notchWidth: 200,
            notchCenterX: 756
        )
    }

    @Test("캡슐은 화면 최상단에 붙는다 — 메뉴바 아래가 아니다")
    func anchorsToScreenTop() {
        let metrics = notchedScreen()
        let origin = metrics.windowOrigin(for: CGSize(width: 460, height: 37))
        // 창의 위쪽 모서리가 화면 위쪽 모서리와 같아야 한다.
        #expect(origin.y + 37 == metrics.screenFrame.maxY)
    }

    @Test("노치 중심에 맞춰 가로 정렬한다")
    func centersOnNotch() {
        let metrics = notchedScreen()
        let size = CGSize(width: 460, height: 37)
        let origin = metrics.windowOrigin(for: size)
        #expect(origin.x + size.width / 2 == metrics.notchCenterX)
    }

    @Test("접힌 높이는 노치 높이 이상이라 노치를 덮는다")
    func collapsedHeightCoversNotch() {
        #expect(notchedScreen().collapsedHeight >= 37)
    }

    @Test("노치가 없는 화면에서는 상단 중앙에 붙는다")
    func fallsBackToTopCenter() {
        let metrics = NotchMetrics.withoutNotch(
            screenFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440)
        )
        #expect(!metrics.hasNotch)
        let size = CGSize(width: 400, height: 30)
        let origin = metrics.windowOrigin(for: size)
        let expectedCenterX: CGFloat = 1280
        let expectedTop: CGFloat = 1440
        #expect(origin.x + size.width / 2 == expectedCenterX)
        #expect(origin.y + size.height == expectedTop)
    }

    @Test("외부 모니터가 오른쪽에 있어도 그 화면 기준으로 배치한다")
    func respectsScreenOrigin() {
        let metrics = NotchMetrics.withoutNotch(
            screenFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        )
        let size = CGSize(width: 400, height: 30)
        let origin = metrics.windowOrigin(for: size)
        let expectedCenterX: CGFloat = 2472
        let expectedTop: CGFloat = 1080
        #expect(origin.x + size.width / 2 == expectedCenterX)
        #expect(origin.y + size.height == expectedTop)
    }
}
