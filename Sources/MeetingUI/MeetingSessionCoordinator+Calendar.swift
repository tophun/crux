import Foundation
import MeetingCalendar
import MeetingCore

/// EventKit 권한과 Google Calendar 연결·해제, 로컬 캐시 동기화.
public extension MeetingSessionCoordinator {
    /// 설정·온보딩의 맥 캘린더 허용 버튼. EventKit 권한을 요청한다.
    func requestCalendarAccess() async {
        do {
            _ = try await calendarProvider.requestAccess()
        } catch {
            calendarSyncError = error.localizedDescription
            log?("캘린더 권한 요청 실패 · \(error.localizedDescription)")
        }
        await refreshPermissions()
        await refreshCalendar(force: true)
        log?("캘린더 상태 · \(calendarStatus.displayName)")
    }

    /// 설정의 Google Calendar 연결 버튼. 아직 연결되지 않았으면 브라우저에서 OAuth를 시작한다.
    func requestGoogleCalendarAccess() async {
        guard !calendarConnectionInProgress else { return }
        calendarConnectionInProgress = true
        calendarSyncError = nil
        log?("Google Calendar 연결 시작")
        defer { calendarConnectionInProgress = false }

        do {
            let granted: Bool = if let preferred = calendarProvider as? PreferredCalendarProvider {
                try await preferred.requestGoogleAccess()
            } else {
                try await calendarProvider.requestAccess()
            }
            let permissionResult = granted ? "허용" : "거부"
            log?("Google OAuth callback 처리 완료 · 권한 결과 \(permissionResult)")
            await refreshCalendar(force: true)
        } catch {
            calendarSyncError = error.localizedDescription
            log?("Google Calendar 연결 실패 · \(error.localizedDescription)")
        }
        await refreshPermissions()
        log?("Google Calendar 상태 · \(googleCalendarStatus.displayName)")
    }

    /// Google Calendar 연결을 해제하고 Keychain 토큰을 폐기한다. EventKit 캐시는 남긴다.
    func disconnectCalendar() async {
        do {
            try await calendarProvider.disconnect()
            calendarSyncError = nil
        } catch {
            calendarSyncError = error.localizedDescription
        }
        await refreshPermissions()
        await refreshCalendar(force: true)
    }

    /// 활성 제공자에서 일정을 읽어 로컬 캐시에 반영한다.
    ///
    /// Google이 연결되어 있으면 Google만 교체하고 EventKit 캐시는 건드리지 않는다.
    /// EventKit만 쓸 때는 upsert만 한다.
    func refreshCalendar(force: Bool = true) async {
        guard calendarProvider.authorizationStatus().canReadEvents else {
            upcomingEvents = []
            return
        }
        let now = Date()
        let usingGoogle = isUsingGoogleCalendar
        if usingGoogle, !force, let lastCalendarRefreshAttemptAt,
           now.timeIntervalSince(lastCalendarRefreshAttemptAt) < 300 {
            loadUpcomingEvents(now: now)
            return
        }
        do {
            let windowStart = now.addingTimeInterval(-3600)
            let windowEnd = now.addingTimeInterval(7 * 24 * 3600)
            let events = try await calendarProvider.events(from: windowStart, to: windowEnd)
            if usingGoogle {
                try calendarRepository.replace(
                    events: events,
                    from: windowStart,
                    to: windowEnd,
                    source: .google
                )
                lastCalendarRefreshAttemptAt = now
                calendarLastUpdatedAt = now
            } else {
                try calendarRepository.save(events: events)
            }
            calendarSyncError = nil
            loadUpcomingEvents(now: now)
        } catch {
            calendarSyncError = error.localizedDescription
            if usingGoogle {
                lastCalendarRefreshAttemptAt = now
            }
            loadUpcomingEvents(now: now)
        }
    }

    var isUsingGoogleCalendar: Bool {
        if let preferred = calendarProvider as? PreferredCalendarProvider {
            return preferred.isGoogleConnected
        }
        return calendarProvider is GoogleCalendarProvider
    }
}
