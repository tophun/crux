import Foundation

/// 일정 스킵 범위. Google·EventKit 참석 상태와는 별개다.
public enum EventSkipScope: String, Sendable, Codable, CaseIterable {
    /// 이번 회차만
    case occurrence
    /// 같은 반복 시리즈 전체
    case series

    public var displayName: String {
        switch self {
        case .occurrence: "이번만"
        case .series: "이 시리즈"
        }
    }
}

/// 이 기기에만 저장하는 스킵 한 건. 일정 본문·토큰은 담지 않는다.
public struct EventSkipRecord: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var eventId: String
    public var seriesId: String?
    public var startDate: Date
    public var scope: EventSkipScope
    public var skippedAt: Date

    public init(
        id: String,
        eventId: String,
        seriesId: String? = nil,
        startDate: Date,
        scope: EventSkipScope,
        skippedAt: Date
    ) {
        self.id = id
        self.eventId = eventId
        self.seriesId = seriesId
        self.startDate = startDate
        self.scope = scope
        self.skippedAt = skippedAt
    }
}

/// 스킵 여부를 O(1)에 가깝게 본다. 저장소가 없으면 빈 인덱스를 쓴다.
public struct EventSkipIndex: Sendable, Hashable {
    public static let empty = EventSkipIndex(records: [])

    public var records: [EventSkipRecord]

    public init(records: [EventSkipRecord]) {
        self.records = records
    }

    public var isEmpty: Bool {
        records.isEmpty
    }

    public func isSkipped(_ event: CalendarEvent) -> Bool {
        scope(for: event) != nil
    }

    public func isSkipped(id: String, seriesId: String?, startDate: Date) -> Bool {
        scope(id: id, seriesId: seriesId, startDate: startDate) != nil
    }

    public func scope(for event: CalendarEvent) -> EventSkipScope? {
        scope(id: event.id, seriesId: event.seriesId, startDate: event.startDate)
    }

    public func scope(id: String, seriesId: String?, startDate: Date) -> EventSkipScope? {
        var occurrence = false
        var series = false
        for record in records {
            switch record.scope {
            case .occurrence:
                if EventSkipPolicy.matchesOccurrence(record, id: id, seriesId: seriesId, startDate: startDate) {
                    occurrence = true
                }
            case .series:
                if EventSkipPolicy.matchesSeries(record, seriesId: seriesId) {
                    series = true
                }
            }
        }
        if series {
            return .series
        }
        if occurrence {
            return .occurrence
        }
        return nil
    }
}

/// 스킵·해제 순수 함수. UI와 저장소는 결과를 반영만 한다.
public enum EventSkipPolicy {
    /// 기록 식별자. 같은 대상에 다시 스킵하면 덮어쓴다.
    public static func recordId(scope: EventSkipScope, eventId: String, seriesId: String?) -> String {
        switch scope {
        case .occurrence:
            "occurrence:\(eventId)"
        case .series:
            "series:\(seriesId ?? eventId)"
        }
    }

    /// 단발 일정에 시리즈 스킵을 고르면 이번만으로 낮춘다.
    public static func resolvedScope(for event: CalendarEvent, scope: EventSkipScope) -> EventSkipScope {
        if scope == .series, event.seriesId == nil {
            return .occurrence
        }
        return scope
    }

    public static func record(
        for event: CalendarEvent,
        scope: EventSkipScope,
        at date: Date = Date()
    ) -> EventSkipRecord {
        let resolved = resolvedScope(for: event, scope: scope)
        return EventSkipRecord(
            id: recordId(scope: resolved, eventId: event.id, seriesId: event.seriesId),
            eventId: event.id,
            seriesId: event.seriesId,
            startDate: event.startDate,
            scope: resolved,
            skippedAt: date
        )
    }

    public static func applying(_ record: EventSkipRecord, to records: [EventSkipRecord]) -> [EventSkipRecord] {
        var next = records.filter { $0.id != record.id }
        next.append(record)
        return next
    }

    /// 이 일정을 다시 대상으로 만든다. 시리즈 스킵이면 같은 시리즈 기록도 지운다.
    public static func removing(event: CalendarEvent, from records: [EventSkipRecord]) -> [EventSkipRecord] {
        records.filter { !matches($0, event) }
    }

    public static func matches(_ record: EventSkipRecord, _ event: CalendarEvent) -> Bool {
        switch record.scope {
        case .occurrence:
            matchesOccurrence(record, id: event.id, seriesId: event.seriesId, startDate: event.startDate)
        case .series:
            matchesSeries(record, seriesId: event.seriesId)
        }
    }

    public static func matchesOccurrence(
        _ record: EventSkipRecord,
        id: String,
        seriesId: String?,
        startDate: Date
    ) -> Bool {
        if record.eventId == id {
            return true
        }
        guard let recordSeries = record.seriesId, let seriesId, recordSeries == seriesId else {
            return false
        }
        return sameStart(record.startDate, startDate)
    }

    public static func matchesSeries(_ record: EventSkipRecord, seriesId: String?) -> Bool {
        guard let recordSeries = record.seriesId, let seriesId else { return false }
        return recordSeries == seriesId
    }

    /// 스킵할 때 지울 로컬 알림 대상. 시리즈면 목록에 있는 같은 시리즈 전부.
    public static func canceledEventIds(
        for record: EventSkipRecord,
        among events: [CalendarEvent]
    ) -> [String] {
        switch record.scope {
        case .occurrence:
            return [record.eventId]
        case .series:
            guard let seriesId = record.seriesId else { return [record.eventId] }
            return events.filter { $0.seriesId == seriesId }.map(\.id)
        }
    }

    public static func sameStart(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince(rhs)) < 1
    }
}
