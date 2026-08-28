import Foundation
@testable import MeetingCore
import Testing

@Suite("일정 로컬 알림 기본 오프셋")
struct EventNotificationSettingsTests {
    @Test("기본값은 시작 10분 전")
    func defaultLeadMinutes() {
        #expect(EventNotificationSettings.defaultLeadMinutes == 10)
        #expect(EventNotificationSettings.standard.leadMinutes == 10)
        #expect(EventNotificationSettings.allowedLeadMinutes == [5, 10, 15, 30])
    }

    @Test("허용되지 않은 오프셋은 기본값으로 맞춘다")
    func clampsUnknownOffset() {
        #expect(EventNotificationSettings.clamped(0) == 10)
        #expect(EventNotificationSettings.clamped(12) == 10)
        #expect(EventNotificationSettings.clamped(-5) == 10)
        #expect(EventNotificationSettings(leadMinutes: 7).leadMinutes == 10)
        #expect(EventNotificationSettings.clamped(15) == 15)
    }

    @Test("알림 시각은 시작에서 오프셋을 뺀다")
    func fireDateSubtractsLead() {
        let start = Date(timeIntervalSince1970: 1_772_000_000)
        let settings = EventNotificationSettings(leadMinutes: 15)
        #expect(settings.fireDate(for: start) == start.addingTimeInterval(-15 * 60))
    }
}

@Suite("일정 로컬 알림 예약·해제")
struct EventNotificationSchedulerTests {
    let now = Date(timeIntervalSince1970: 1_772_000_000)

    private func makeEvent(id: String = "evt-1", startOffset: TimeInterval = 3600) -> CalendarEvent {
        let start = now.addingTimeInterval(startOffset)
        return CalendarEvent(
            id: id,
            title: "주간 유저성장 회의",
            startDate: start,
            endDate: start.addingTimeInterval(2700),
            attendees: [EventAttendee(name: "김민수", isOrganizer: true)],
            location: "회의실 A"
        )
    }

    @Test("알림을 예약하면 시작 N분 전에 건다")
    func schedulesLeadBeforeStart() async throws {
        let center = FakeEventNotificationCenter()
        let scheduler = EventNotificationScheduler(center: center)
        let event = makeEvent()
        let settings = EventNotificationSettings(leadMinutes: 15)

        let request = try await scheduler.schedule(event: event, settings: settings, now: now)

        #expect(request.eventId == event.id)
        #expect(request.identifier == EventNotificationScheduler.identifier(eventId: event.id))
        #expect(request.fireDate == event.startDate.addingTimeInterval(-15 * 60))
        #expect(request.leadMinutes == 15)
        #expect(request.body == "15분 후 시작합니다")
        #expect(await scheduler.isScheduled(eventId: event.id))
        #expect(await center.pendingCount() == 1)
    }

    @Test("설정 기본 오프셋을 그대로 쓴다")
    func usesDefaultOffsetFromSettings() async throws {
        let center = FakeEventNotificationCenter()
        let scheduler = EventNotificationScheduler(center: center)
        let event = makeEvent()

        let request = try await scheduler.schedule(event: event, now: now)

        #expect(request.leadMinutes == EventNotificationSettings.defaultLeadMinutes)
        #expect(request.fireDate == event.startDate.addingTimeInterval(-10 * 60))
        #expect(request.body == EventNotificationScheduler.reminderBody(leadMinutes: 10))
    }

    @Test("이미 있는 알림은 켜짐으로 보고 해제하면 예약만 지운다")
    func cancelRemovesPendingOnly() async throws {
        let center = FakeEventNotificationCenter()
        let scheduler = EventNotificationScheduler(center: center)
        let event = makeEvent()
        _ = try await scheduler.schedule(event: event, now: now)
        #expect(await scheduler.isScheduled(eventId: event.id))

        await scheduler.cancel(eventId: event.id)

        #expect(await scheduler.isScheduled(eventId: event.id) == false)
        #expect(await center.pendingCount() == 0)
        #expect(await center.removedIdentifiers() == [EventNotificationScheduler.identifier(eventId: event.id)])
    }

    @Test("같은 일정을 다시 예약하면 식별자가 같다")
    func identifierIsStablePerEvent() async throws {
        let center = FakeEventNotificationCenter()
        let scheduler = EventNotificationScheduler(center: center)
        let event = makeEvent(id: "same-event")

        let first = try await scheduler.schedule(
            event: event,
            settings: EventNotificationSettings(leadMinutes: 5),
            now: now
        )
        let second = try await scheduler.schedule(
            event: event,
            settings: EventNotificationSettings(leadMinutes: 30),
            now: now
        )

        #expect(first.identifier == second.identifier)
        #expect(first.identifier == "crux.event.same-event")
        #expect(await center.pendingCount() == 1)
        #expect(second.leadMinutes == 30)
    }

    @Test("권한이 없으면 예약하지 않는다")
    func deniedDoesNotSchedule() async {
        let center = FakeEventNotificationCenter(authorization: .denied)
        let scheduler = EventNotificationScheduler(center: center)
        let event = makeEvent()

        await #expect(throws: EventNotificationError.denied) {
            try await scheduler.schedule(event: event, now: now)
        }
        #expect(await center.pendingCount() == 0)
        #expect(await scheduler.isScheduled(eventId: event.id) == false)
    }

    @Test("시작이 지난 알림은 걸지 않는다")
    func rejectsPastFireDate() async {
        let center = FakeEventNotificationCenter()
        let scheduler = EventNotificationScheduler(center: center)
        let event = makeEvent(startOffset: 60)

        await #expect(throws: EventNotificationError.fireDatePassed) {
            try await scheduler.schedule(
                event: event,
                settings: EventNotificationSettings(leadMinutes: 10),
                now: now
            )
        }
        #expect(await center.pendingCount() == 0)
    }

    @Test("일정 필드는 예약 뒤에도 그대로다")
    func doesNotMutateCalendarEvent() async throws {
        let center = FakeEventNotificationCenter()
        let scheduler = EventNotificationScheduler(center: center)
        let event = makeEvent()
        let before = event

        _ = try await scheduler.schedule(event: event, now: now)

        #expect(event == before)
        #expect(event.title == before.title)
        #expect(event.startDate == before.startDate)
        #expect(event.location == before.location)
        #expect(event.alarmOffsets == before.alarmOffsets)
    }
}

/// 메모리에만 예약을 쌓는 알림 센터. UserNotifications를 쓰지 않는다.
final class FakeEventNotificationCenter: EventNotificationCenter, @unchecked Sendable {
    private let lock = NSLock()
    private var authorization: EventNotificationAuthorization
    private var pending: [String: EventNotificationRequest] = [:]
    private var removed: [String] = []

    init(authorization: EventNotificationAuthorization = .authorized) {
        self.authorization = authorization
    }

    func authorizationStatus() async -> EventNotificationAuthorization {
        lock.withLock { authorization }
    }

    func requestAuthorization() async -> EventNotificationAuthorization {
        lock.withLock { authorization }
    }

    func pendingIdentifiers() async -> Set<String> {
        lock.withLock { Set(pending.keys) }
    }

    func add(_ request: EventNotificationRequest) async throws {
        try lock.withLock {
            guard authorization.allowsScheduling else {
                throw EventNotificationError.denied
            }
            pending[request.identifier] = request
        }
    }

    func removePending(identifiers: [String]) async {
        lock.withLock {
            for identifier in identifiers {
                pending.removeValue(forKey: identifier)
                removed.append(identifier)
            }
        }
    }

    func pendingCount() -> Int {
        lock.withLock { pending.count }
    }

    func removedIdentifiers() -> [String] {
        lock.withLock { removed }
    }
}
