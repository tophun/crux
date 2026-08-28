import MeetingCore
import SwiftUI

/// 다가오는 일정 목록. 제목, 시작/끝, 캘린더, 회의 링크를 보여 준다.
public struct UpcomingEventListView: View {
    @Bindable var store: UpcomingCalendarStore

    public init(store: UpcomingCalendarStore) {
        self.store = store
    }

    public var body: some View {
        Group {
            if !store.authorization.canReadEvents {
                ContentUnavailableView {
                    Label("캘린더 권한이 필요합니다", systemImage: "calendar.badge.exclamationmark")
                } description: {
                    Text("macOS 캘린더 일정을 이 기기에서만 읽습니다. 오디오와 전사문은 보내지 않습니다.")
                } actions: {
                    Button("허용…") {
                        Task { await store.requestAccess() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.rows.isEmpty {
                ContentUnavailableView(
                    "다가오는 일정이 없습니다",
                    systemImage: "calendar",
                    description: Text("종일·취소·거절한 일정은 기본으로 숨깁니다.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(
                    get: { store.selectedEventId },
                    set: { store.selectedEventId = $0 }
                )) {
                    ForEach(store.rows) { row in
                        UpcomingEventRowView(row: row)
                            .tag(row.id)
                    }
                }
            }
        }
        .overlay {
            if store.isLoading, store.rows.isEmpty, store.authorization.canReadEvents {
                ProgressView()
            }
        }
        .task { await store.reload() }
    }
}

struct UpcomingEventRowView: View {
    let row: UpcomingEventRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.title)
                .font(.headline)
                .lineLimit(1)
            Text(timeRange)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                if let calendar = row.calendarTitle, !calendar.isEmpty {
                    Text(calendar)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if row.conferenceURL != nil {
                    Label("회의 링크", systemImage: "video")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var timeRange: String {
        let start = row.startDate.formatted(.dateTime.month().day().hour().minute())
        let end = row.endDate.formatted(.dateTime.hour().minute())
        return "\(start) – \(end)"
    }
}
