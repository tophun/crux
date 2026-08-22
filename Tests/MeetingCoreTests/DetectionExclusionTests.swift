import Foundation
import Testing

@testable import MeetingCore

@Suite("회의 감지 제외 사유")
struct DetectionExclusionTests {
    private func event(
        attendees: Int,
        allDay: Bool = false,
        status: CalendarEventStatus = .confirmed,
        minutes: Double = 30
    ) -> CalendarEvent {
        let start = Date()
        return CalendarEvent(
            id: UUID().uuidString,
            title: "테스트 일정",
            startDate: start,
            endDate: start.addingTimeInterval(minutes * 60),
            isAllDay: allDay,
            status: status,
            attendees: (0 ..< attendees).map { EventAttendee(name: "참석자 \($0)", email: "a\($0)@example.com") }
        )
    }

    @Test("혼자만 있는 일정은 참석자 부족으로 빠진다 — 캡슐이 뜨지 않는 가장 흔한 이유다")
    func soloEventExcluded() {
        let policy = MeetingDetectionPolicy()
        let solo = event(attendees: 0)
        #expect(policy.exclusionReason(for: solo) == .tooFewAttendees)
        #expect(policy.eligibleEvents([solo]).isEmpty)
    }

    @Test("참석자 기준을 0으로 낮추면 혼자 만든 일정도 감지한다")
    func soloEventAllowedWhenConfigured() {
        var configuration = MeetingDetectionPolicy.Configuration()
        configuration.minimumAttendees = 0
        let policy = MeetingDetectionPolicy(configuration: configuration)
        #expect(policy.exclusionReason(for: event(attendees: 0)) == nil)
    }

    @Test("종일·취소·길이 0은 기준을 낮춰도 빠진다")
    func alwaysExcluded() {
        var configuration = MeetingDetectionPolicy.Configuration()
        configuration.minimumAttendees = 0
        let policy = MeetingDetectionPolicy(configuration: configuration)
        #expect(policy.exclusionReason(for: event(attendees: 2, allDay: true)) == .allDay)
        #expect(policy.exclusionReason(for: event(attendees: 2, status: .canceled)) == .canceled)
        #expect(policy.exclusionReason(for: event(attendees: 2, minutes: 0)) == .zeroDuration)
    }

    @Test("제외 목록은 이유와 함께 돌려준다")
    func reportsExclusions() {
        let policy = MeetingDetectionPolicy()
        let exclusions = policy.exclusions([event(attendees: 0), event(attendees: 3)])
        #expect(exclusions.count == 1)
        #expect(exclusions.first?.reason == .tooFewAttendees)
    }
}

@Suite("캡슐 표시 시점")
struct DetectionLeadTimeTests {
    private func event(startsIn seconds: TimeInterval, alarms: [TimeInterval] = [], now: Date) -> CalendarEvent {
        let start = now.addingTimeInterval(seconds)
        return CalendarEvent(
            id: UUID().uuidString,
            title: "주간 회의",
            startDate: start,
            endDate: start.addingTimeInterval(1800),
            attendees: [EventAttendee(name: "가"), EventAttendee(name: "나")],
            alarmOffsets: alarms
        )
    }

    @Test("일정에 1분 전 알림이 걸려 있으면 1분 전부터 뜬다")
    func followsEventAlarm() {
        let now = Date()
        let policy = MeetingDetectionPolicy()
        let target = event(startsIn: 120, alarms: [-60], now: now)
        #expect(policy.leadTime(for: target) == 60)

        // 2분 전에는 아직 뜨지 않는다.
        #expect(policy.decide(events: [target], now: now, notifiedEventIds: []) == .idle)
        // 30초 전에는 뜬다.
        let later = now.addingTimeInterval(90)
        if case let .imminent(shown, _) = policy.decide(events: [target], now: later, notifiedEventIds: []) {
            #expect(shown.id == target.id)
        } else {
            Issue.record("알림 시각이 지나면 임박 상태여야 한다")
        }
    }

    @Test("알림이 없으면 기본값 5분 전부터 뜬다")
    func fallsBackToDefault() {
        let policy = MeetingDetectionPolicy()
        #expect(policy.leadTime(for: event(startsIn: 600, now: Date())) == 300)
    }

    @Test("알림이 여러 개면 가장 이른 알림에 맞춘다")
    func usesEarliestAlarm() {
        let policy = MeetingDetectionPolicy()
        #expect(policy.leadTime(for: event(startsIn: 600, alarms: [-60, -600], now: Date())) == 600)
    }

    @Test("하루 전 알림이어도 최대치를 넘겨 미리 띄우지 않는다")
    func capsVeryEarlyAlarm() {
        let policy = MeetingDetectionPolicy()
        let target = event(startsIn: 7200, alarms: [-86400], now: Date())
        #expect(policy.leadTime(for: target) == 3600)
    }

    @Test("시작 시각에 알림이 걸린 일정도 시작하면 확인을 묻는다")
    func promptsAtStart() {
        let now = Date()
        let policy = MeetingDetectionPolicy()
        let target = event(startsIn: 0, alarms: [0], now: now)
        if case let .started(shown, _) = policy.decide(events: [target], now: now, notifiedEventIds: []) {
            #expect(shown.id == target.id)
        } else {
            Issue.record("시작 시각에는 확인을 물어야 한다")
        }
    }
}
