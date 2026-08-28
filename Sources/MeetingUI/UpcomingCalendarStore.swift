import Foundation
import MeetingCore
import MeetingPersistence
import Observation

/// 메인 창 사이드바에서 고르는 목록.
public enum MainLibrary: String, CaseIterable, Identifiable, Sendable {
    case meetings
    case calendar

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .meetings: "회의록"
        case .calendar: "일정"
        }
    }
}

/// 다가오는 일정 목록. Google이 연결되어 있으면 그쪽을, 없으면 EventKit을 읽고 로컬에만 저장한다.
///
/// 알림(#27)·스킵(#28)은 이 저장소에 두지 않는다.
@MainActor
@Observable
public final class UpcomingCalendarStore {
    public private(set) var events: [CalendarEvent] = []
    public private(set) var rows: [UpcomingEventRow] = []
    public var selectedEventId: String? {
        didSet { syncSelection() }
    }

    public private(set) var selectedEvent: CalendarEvent?
    public private(set) var authorization: CalendarAuthorizationStatus = .notDetermined
    public private(set) var isLoading = false
    public private(set) var lastError: String?

    private let provider: any CalendarProvider
    private let repository: CalendarRepository?
    private let catalog: UpcomingEventCatalog

    public init(
        provider: any CalendarProvider,
        repository: CalendarRepository? = nil,
        catalog: UpcomingEventCatalog = UpcomingEventCatalog()
    ) {
        self.provider = provider
        self.repository = repository
        self.catalog = catalog
    }

    public func requestAccess() async {
        _ = try? await provider.requestAccess()
        await reload()
    }

    public func reload(now: Date = Date()) async {
        isLoading = true
        lastError = nil
        authorization = provider.authorizationStatus()
        defer { isLoading = false }

        guard authorization.canReadEvents else {
            events = []
            rows = []
            selectedEvent = nil
            selectedEventId = nil
            return
        }

        do {
            let fetched = try await provider.events(
                from: catalog.fetchStart(now: now),
                to: catalog.fetchEnd(now: now)
            )
            try? repository?.save(events: fetched)
            apply(fetched, now: now)
        } catch {
            lastError = error.localizedDescription
            events = []
            rows = []
            selectedEvent = nil
        }
    }

    private func apply(_ fetched: [CalendarEvent], now: Date) {
        events = catalog.visibleEvents(fetched, now: now)
        rows = catalog.rows(from: fetched, now: now)
        if selectedEventId == nil || !events.contains(where: { $0.id == selectedEventId }) {
            selectedEventId = events.first?.id
        }
        syncSelection()
    }

    private func syncSelection() {
        selectedEvent = events.first { $0.id == selectedEventId }
    }
}
