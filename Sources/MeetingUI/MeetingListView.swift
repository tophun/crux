import MeetingCore
import SwiftUI

/// 회의 목록(§11). 날짜, 제목, 처리 상태, 요약 미리보기, 액션아이템 개수를 보여 준다.
public struct MeetingListView: View {
    @Bindable var state: AppState

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        List(selection: Binding(
            get: { state.selectedMeetingId },
            set: { state.selectedMeetingId = $0 }
        )) {
            if state.summaries.isEmpty {
                ContentUnavailableView(
                    "회의가 없습니다",
                    systemImage: "waveform",
                    description: Text("오디오 파일을 가져오면 이 기기에서 전사와 회의록 생성이 진행됩니다.")
                )
            }
            ForEach(state.summaries) { summary in
                MeetingRow(summary: summary)
                    .tag(summary.id)
                    .contextMenu {
                        Button("회의록 열기") { state.selectedMeetingId = summary.id }
                        Divider()
                        Button("회의 삭제…", role: .destructive) {
                            state.requestDelete(meetingId: summary.id)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button("삭제", role: .destructive) {
                            state.requestDelete(meetingId: summary.id)
                        }
                    }
            }
        }
        .deleteConfirmation(state: state)
    }
}

struct MeetingRow: View {
    let summary: MeetingSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(summary.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                StatusBadge(status: summary.meeting.status)
            }
            Text(summary.meeting.startedAt, format: .dateTime.year().month().day().hour().minute())
                .font(.caption)
                .foregroundStyle(.secondary)
            if let preview = summary.summaryPreview, !preview.isEmpty {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

struct StatusBadge: View {
    let status: MeetingStatus
    /// 목록 행이 선택되면 배경이 강조색(파랑)이 된다. 그 위에서도 읽히도록 흰 배경으로 바꾼다.
    @Environment(\.backgroundProminence) private var backgroundProminence

    var body: some View {
        let selected = backgroundProminence == .increased
        Text(status.displayName)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(selected ? Color.white.opacity(0.9) : color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .completed: .green
        case .failed: .red
        case .transcribing, .analyzing: .blue
        case .recording: .red
        case .paused: .orange
        case .recorded: .secondary
        }
    }
}

/// 삭제 확인 대화상자. 목록과 상세 화면에서 같은 문구를 쓴다.
extension View {
    func deleteConfirmation(state: AppState) -> some View {
        confirmationDialog(
            state.pendingDeletion.map { "‘\($0.displayTitle)’를 삭제할까요?" } ?? "회의를 삭제할까요?",
            isPresented: Binding(
                get: { state.pendingDeletion != nil },
                set: { if !$0 { state.cancelDelete() } }
            ),
            titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) { state.confirmDelete() }
            Button("취소", role: .cancel) { state.cancelDelete() }
        } message: {
            Text("녹음 파일, 전사문, 회의록, 근거 기록이 모두 사라집니다. 파일은 휴지통으로 보내며 데이터베이스 기록은 바로 삭제됩니다.")
        }
    }
}
