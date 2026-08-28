import MeetingCore
import SwiftUI

/// 다가오는 일정 상세. 시간, 참석자, 회의 링크, 로컬 알림을 보여 준다.
///
/// 알림은 이 기기 `UNUserNotificationCenter`만 쓴다. 스킵과 오디오·전사문은 없다.
public struct UpcomingEventDetailView: View {
    @Bindable var store: UpcomingCalendarStore
    @Bindable var notifications: EventNotificationStore

    public init(store: UpcomingCalendarStore, notifications: EventNotificationStore) {
        self.store = store
        self.notifications = notifications
    }

    public var body: some View {
        if let event = store.selectedEvent {
            Form {
                Section {
                    LabeledContent("시간", value: timeRange(for: event))
                    if let calendar = event.calendarTitle, !calendar.isEmpty {
                        LabeledContent("캘린더", value: calendar)
                    }
                    if let location = event.location, !location.isEmpty {
                        LabeledContent("장소", value: location)
                    }
                    if let url = event.conferenceURL {
                        LabeledContent("회의 링크") {
                            Link(url.absoluteString, destination: url)
                        }
                    }
                } header: {
                    Text(event.title)
                }

                Section {
                    notificationToggle(for: event)
                    if notifications.authorization == .denied {
                        LabeledContent {
                            Button("시스템 설정 열기") {
                                notifications.openSystemSettings()
                            }
                        } label: {
                            Text("알림이 꺼져 있습니다")
                            Text("시스템 설정에서 알림을 허용하면 예약할 수 있습니다.")
                        }
                    }
                    if let message = notifications.lastError, notifications.authorization != .denied {
                        Text(message)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("알림")
                } footer: {
                    Text("이 기기에서만 울립니다. Google·캘린더 알림은 바꾸지 않습니다.")
                }

                Section("참석자") {
                    if event.attendees.isEmpty {
                        Text("참석자 정보가 없습니다")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(event.attendees, id: \.self) { attendee in
                            LabeledContent {
                                if let status = attendee.responseStatus {
                                    Text(status.displayName)
                                        .foregroundStyle(.secondary)
                                }
                            } label: {
                                Text(attendee.displayName)
                                if attendee.isOrganizer {
                                    Text("주최자")
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(event.title)
            .task(id: event.id) { await notifications.refresh() }
        } else {
            Color.clear
        }
    }

    private func notificationToggle(for event: CalendarEvent) -> some View {
        Toggle(isOn: Binding(
            get: { notifications.isScheduled(event.id) },
            set: { newValue in
                Task { await notifications.setScheduled(newValue, event: event) }
            }
        )) {
            Text("시작 \(notifications.leadMinutes)분 전")
            Text("설정에서 기본 시각을 바꿀 수 있습니다.")
        }
    }

    private func timeRange(for event: CalendarEvent) -> String {
        let start = event.startDate.formatted(.dateTime.year().month().day().hour().minute())
        let end = event.endDate.formatted(.dateTime.month().day().hour().minute())
        return "\(start) – \(end)"
    }
}
