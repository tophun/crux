import Foundation
@testable import MeetingCore
import Testing

@Suite("일정 스킵 이번만·시리즈")
struct EventSkipPolicyTests {
    let now = Date(timeIntervalSince1970: 1_772_000_000)

    private func occurrence(
        id: String,
        seriesId: String? = "series-weekly",
        startOffset: TimeInterval
    ) -> CalendarEvent {
        let start = now.addingTimeInterval(startOffset)
        return CalendarEvent(
            id: id,
            seriesId: seriesId,
            title: "주간 스탠드업",
            startDate: start,
            endDate: start.addingTimeInterval(1800),
            attendees: [EventAttendee(name: "가"), EventAttendee(name: "나")]
        )
    }

    @Test("이번만 건너뛰면 같은 시리즈의 다른 회차는 남는다")
    func occurrenceSkipLeavesOtherOccurrences() {
        let thisWeek = occurrence(id: "weekly#1", startOffset: 3600)
        let nextWeek = occurrence(id: "weekly#2", startOffset: 3600 + 7 * 24 * 3600)
        let record = EventSkipPolicy.record(for: thisWeek, scope: .occurrence, at: now)
        let index = EventSkipIndex(records: [record])

        #expect(record.scope == .occurrence)
        #expect(index.isSkipped(thisWeek))
        #expect(index.scope(for: thisWeek) == .occurrence)
        #expect(!index.isSkipped(nextWeek))
    }

    @Test("시리즈를 건너뛰면 같은 시리즈의 모든 회차가 빠진다")
    func seriesSkipMatchesAllOccurrences() {
        let thisWeek = occurrence(id: "weekly#1", startOffset: 3600)
        let nextWeek = occurrence(id: "weekly#2", startOffset: 3600 + 7 * 24 * 3600)
        let other = occurrence(id: "other#1", seriesId: "series-other", startOffset: 7200)
        let record = EventSkipPolicy.record(for: thisWeek, scope: .series, at: now)
        let index = EventSkipIndex(records: [record])

        #expect(record.scope == .series)
        #expect(index.isSkipped(thisWeek))
        #expect(index.isSkipped(nextWeek))
        #expect(index.scope(for: nextWeek) == .series)
        #expect(!index.isSkipped(other))
    }

    @Test("단발 일정의 시리즈 스킵은 이번만으로 낮춘다")
    func seriesOnOneOffBecomesOccurrence() {
        let oneOff = occurrence(id: "one-off", seriesId: nil, startOffset: 1800)
        let record = EventSkipPolicy.record(for: oneOff, scope: .series, at: now)
        #expect(record.scope == .occurrence)
        #expect(EventSkipIndex(records: [record]).isSkipped(oneOff))
    }

    @Test("이번만 해면 그 회차만 다시 대상이 된다")
    func unskipOccurrenceRestoresOnlyThatTime() {
        let thisWeek = occurrence(id: "weekly#1", startOffset: 3600)
        let nextWeek = occurrence(id: "weekly#2", startOffset: 3600 + 7 * 24 * 3600)
        var records = [
            EventSkipPolicy.record(for: thisWeek, scope: .occurrence, at: now),
            EventSkipPolicy.record(for: nextWeek, scope: .occurrence, at: now)
        ]
        records = EventSkipPolicy.removing(event: thisWeek, from: records)
        let index = EventSkipIndex(records: records)

        #expect(!index.isSkipped(thisWeek))
        #expect(index.isSkipped(nextWeek))
    }

    @Test("시리즈를 해면 같은 시리즈가 다시 대상이 된다")
    func unskipSeriesRestoresAllOccurrences() {
        let thisWeek = occurrence(id: "weekly#1", startOffset: 3600)
        let nextWeek = occurrence(id: "weekly#2", startOffset: 3600 + 7 * 24 * 3600)
        let records = EventSkipPolicy.removing(
            event: nextWeek,
            from: [EventSkipPolicy.record(for: thisWeek, scope: .series, at: now)]
        )
        let index = EventSkipIndex(records: records)

        #expect(records.isEmpty)
        #expect(!index.isSkipped(thisWeek))
        #expect(!index.isSkipped(nextWeek))
    }

    @Test("시리즈 스킵은 목록에 있는 같은 시리즈 알림만 지운다")
    func seriesCancelTargetsLoadedOccurrences() {
        let thisWeek = occurrence(id: "weekly#1", startOffset: 3600)
        let nextWeek = occurrence(id: "weekly#2", startOffset: 3600 + 7 * 24 * 3600)
        let other = occurrence(id: "other#1", seriesId: "series-other", startOffset: 7200)
        let record = EventSkipPolicy.record(for: thisWeek, scope: .series, at: now)
        let ids = EventSkipPolicy.canceledEventIds(for: record, among: [thisWeek, nextWeek, other])
        #expect(Set(ids) == ["weekly#1", "weekly#2"])
    }

    @Test("이번만 스킵은 그 일정 알림만 지운다")
    func occurrenceCancelTargetsOneEvent() {
        let thisWeek = occurrence(id: "weekly#1", startOffset: 3600)
        let nextWeek = occurrence(id: "weekly#2", startOffset: 3600 + 7 * 24 * 3600)
        let record = EventSkipPolicy.record(for: thisWeek, scope: .occurrence, at: now)
        #expect(EventSkipPolicy.canceledEventIds(for: record, among: [thisWeek, nextWeek]) == ["weekly#1"])
    }

    @Test("반복 회차 id는 시리즈와 시작 시각으로 만든다")
    func occurrenceIdentityIsUniquePerStart() {
        let start = now.addingTimeInterval(3600)
        let later = start.addingTimeInterval(7 * 24 * 3600)
        let first = CalendarEvent.identity(eventIdentifier: "series-a", startDate: start, isRecurring: true)
        let second = CalendarEvent.identity(eventIdentifier: "series-a", startDate: later, isRecurring: true)
        let oneOff = CalendarEvent.identity(eventIdentifier: "one-off", startDate: start, isRecurring: false)

        #expect(first.seriesId == "series-a")
        #expect(second.seriesId == "series-a")
        #expect(first.id != second.id)
        #expect(first.id == CalendarEvent.occurrenceIdentifier(seriesId: "series-a", startDate: start))
        #expect(oneOff.id == "one-off")
        #expect(oneOff.seriesId == nil)
    }

    @Test("예전 일정 JSON에 seriesId가 없어도 읽는다")
    func decodesEventWithoutSeriesId() throws {
        let original = CalendarEvent(
            id: "evt-old",
            title: "옛 일정",
            startDate: Date(timeIntervalSince1970: 1_772_000_000),
            endDate: Date(timeIntervalSince1970: 1_772_001_800)
        )
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original))
        guard var dictionary = object as? [String: Any] else {
            Issue.record("일정 JSON 객체를 만들지 못했다")
            return
        }
        dictionary.removeValue(forKey: "seriesId")
        let event = try JSONDecoder().decode(
            CalendarEvent.self,
            from: JSONSerialization.data(withJSONObject: dictionary)
        )
        #expect(event.id == "evt-old")
        #expect(event.seriesId == nil)
        #expect(!event.isRecurring)
        #expect(event.title == "옛 일정")
    }
}

@Suite("스킵한 일정의 감지·알림")
struct EventSkipSideEffectTests {
    let now = Date(timeIntervalSince1970: 1_772_000_000)

    private func makeEvent(
        id: String,
        seriesId: String? = nil,
        startOffset: TimeInterval
    ) -> CalendarEvent {
        let start = now.addingTimeInterval(startOffset)
        return CalendarEvent(
            id: id,
            seriesId: seriesId,
            title: "주간 유저성장 회의",
            startDate: start,
            endDate: start.addingTimeInterval(3600),
            attendees: [EventAttendee(name: "가"), EventAttendee(name: "나")]
        )
    }

    @Test("이번만 건너뛴 일정은 녹음 확인을 띄우지 않는다")
    func occurrenceSkipHidesRecordPrompt() {
        let event = makeEvent(id: "evt-1", seriesId: "series-a", startOffset: -60)
        let sibling = makeEvent(id: "evt-2", seriesId: "series-a", startOffset: 7 * 24 * 3600)
        let skip = EventSkipIndex(records: [EventSkipPolicy.record(for: event, scope: .occurrence, at: now)])
        let policy = MeetingDetectionPolicy()

        #expect(policy.exclusionReason(for: event, skipIndex: skip) == .skipped)
        #expect(policy.decide(events: [event], now: now, notifiedEventIds: [], skipIndex: skip) == .idle)
        #expect(policy.exclusionReason(for: sibling, skipIndex: skip) == nil)
    }

    @Test("시리즈를 건너뛰면 다른 회차도 녹음 확인을 띄우지 않는다")
    func seriesSkipHidesRecordPromptForAll() {
        let first = makeEvent(id: "evt-1", seriesId: "series-a", startOffset: -60)
        let second = makeEvent(id: "evt-2", seriesId: "series-a", startOffset: 120)
        let skip = EventSkipIndex(records: [EventSkipPolicy.record(for: first, scope: .series, at: now)])
        let policy = MeetingDetectionPolicy()

        #expect(policy.eligibleEvents([first, second], skipIndex: skip).isEmpty)
        #expect(policy.decide(events: [first, second], now: now, notifiedEventIds: [], skipIndex: skip) == .idle)
    }

    @Test("건너뛴 일정은 알림을 걸지 못하고 대기 예약을 지운다")
    func skippedEventCancelsPendingNotification() async throws {
        let center = FakeEventNotificationCenter()
        let scheduler = EventNotificationScheduler(center: center)
        let event = makeEvent(id: "evt-notify", startOffset: 3600)
        _ = try await scheduler.schedule(event: event, now: now)
        #expect(await scheduler.isScheduled(eventId: event.id))

        let skip = EventSkipIndex(records: [EventSkipPolicy.record(for: event, scope: .occurrence, at: now)])
        await #expect(throws: EventNotificationError.skipped) {
            try await scheduler.schedule(event: event, now: now, skipIndex: skip)
        }
        #expect(await scheduler.isScheduled(eventId: event.id) == false)
        #expect(await center.pendingCount() == 0)
    }

    @Test("시리즈 스킵은 같은 시리즈의 대기 알림을 모두 지운다")
    func seriesSkipCancelsAllPendingInSeries() async throws {
        let center = FakeEventNotificationCenter()
        let scheduler = EventNotificationScheduler(center: center)
        let first = makeEvent(id: "evt-1", seriesId: "series-a", startOffset: 3600)
        let second = makeEvent(id: "evt-2", seriesId: "series-a", startOffset: 7200)
        _ = try await scheduler.schedule(event: first, now: now)
        _ = try await scheduler.schedule(event: second, now: now)

        let record = EventSkipPolicy.record(for: first, scope: .series, at: now)
        await scheduler.cancel(eventIds: EventSkipPolicy.canceledEventIds(for: record, among: [first, second]))

        #expect(await scheduler.isScheduled(eventId: first.id) == false)
        #expect(await scheduler.isScheduled(eventId: second.id) == false)
        #expect(await center.pendingCount() == 0)
    }

    @Test("해제하면 다시 녹음 확인 대상이 된다")
    func unskipRestoresDetection() {
        let event = makeEvent(id: "evt-1", startOffset: -60)
        let skipped = [EventSkipPolicy.record(for: event, scope: .occurrence, at: now)]
        let restored = EventSkipPolicy.removing(event: event, from: skipped)
        let policy = MeetingDetectionPolicy()

        #expect(policy.decide(
            events: [event],
            now: now,
            notifiedEventIds: [],
            skipIndex: EventSkipIndex(records: skipped)
        ) == .idle)

        if case let .started(shown, _) = policy.decide(
            events: [event],
            now: now,
            notifiedEventIds: [],
            skipIndex: EventSkipIndex(records: restored)
        ) {
            #expect(shown.id == event.id)
        } else {
            Issue.record("해제 뒤에는 시작 확인을 물어야 한다")
        }
    }
}
