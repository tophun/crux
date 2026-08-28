import AppKit
import Foundation
import MeetingCore
import Observation

/// 일정 상세의 로컬 알림 상태. 캘린더 목록 저장소와 분리한다.
///
/// Google 일정은 읽기만 하고, 알림은 이 기기 예약만 다룬다.
@MainActor
@Observable
public final class EventNotificationStore {
    public private(set) var authorization: EventNotificationAuthorization = .notDetermined
    public private(set) var scheduledEventIds: Set<String> = []
    public private(set) var lastError: String?

    public var leadMinutes: Int {
        didSet { EventNotificationPreferenceStore.leadMinutes = leadMinutes }
    }

    private let scheduler: EventNotificationScheduler

    public init(center: any EventNotificationCenter) {
        scheduler = EventNotificationScheduler(center: center)
        leadMinutes = EventNotificationPreferenceStore.leadMinutes
    }

    public func isScheduled(_ eventId: String) -> Bool {
        scheduledEventIds.contains(eventId)
    }

    public func refresh() async {
        authorization = await scheduler.authorizationStatus()
        scheduledEventIds = await scheduler.scheduledEventIds()
    }

    /// 토글을 반영한다. 켜면 기본 오프셋으로 예약하고, 끄면 대기 예약만 지운다.
    public func setScheduled(_ enabled: Bool, event: CalendarEvent) async {
        lastError = nil
        if enabled {
            do {
                _ = try await scheduler.schedule(
                    event: event,
                    settings: EventNotificationSettings(leadMinutes: leadMinutes)
                )
            } catch EventNotificationError.denied {
                lastError = EventNotificationError.denied.errorDescription
            } catch {
                lastError = error.localizedDescription
            }
        } else {
            await scheduler.cancel(eventId: event.id)
        }
        await refresh()
    }

    public func requestAuthorization() async {
        authorization = await scheduler.requestAuthorization()
        if authorization == .denied {
            lastError = EventNotificationError.denied.errorDescription
        }
    }

    /// 한 번 거부하면 앱에서 다시 물을 수 없다. 시스템 알림 설정으로 보낸다.
    public func openSystemSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications"
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
