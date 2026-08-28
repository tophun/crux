import MeetingCore
import SwiftUI

/// 다가오는 일정 상세. 시간, 참석자, 회의 링크만 보여 준다.
///
/// 알림 등록과 스킵은 넣지 않는다. 오디오·전사문도 이 화면에 없다.
public struct UpcomingEventDetailView: View {
    @Bindable var store: UpcomingCalendarStore

    public init(store: UpcomingCalendarStore) {
        self.store = store
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
        } else {
            Color.clear
        }
    }

    private func timeRange(for event: CalendarEvent) -> String {
        let start = event.startDate.formatted(.dateTime.year().month().day().hour().minute())
        let end = event.endDate.formatted(.dateTime.month().day().hour().minute())
        return "\(start) – \(end)"
    }
}
