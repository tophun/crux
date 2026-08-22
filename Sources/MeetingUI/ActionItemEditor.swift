import MeetingCore
import SwiftUI

/// 액션아이템 편집(§11). 작업 내용·담당자·마감일·상태를 사용자가 수정할 수 있고 근거는 유지된다.
struct ActionItemsTab: View {
    @Bindable var state: AppState
    let detail: MeetingDetail
    @State private var editing: ActionItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                let items = detail.note?.actionItems ?? []
                HStack {
                    Text("액션아이템").font(.headline)
                    Spacer()
                    Button("항목 추가", systemImage: "plus") {
                        editing = ActionItem(task: "")
                    }
                    .buttonStyle(.bordered)
                    .disabled(detail.note == nil)
                }
                if items.isEmpty {
                    Text("액션아이템이 없습니다.").foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.task).font(.body)
                            Spacer()
                            Button("수정") { editing = item }
                                .buttonStyle(.link)
                            Button("삭제", role: .destructive) { remove(item) }
                                .buttonStyle(.link)
                        }
                        HStack(spacing: 12) {
                            Label(item.assigneeDisplay, systemImage: "person")
                            Label(item.dueDateDisplay, systemImage: "calendar")
                            Label(item.status.displayName, systemImage: "flag")
                        }
                        .font(.caption)
                        .foregroundStyle(item.assignee == nil || item.dueDate == nil ? .orange : .secondary)
                        EvidenceView(
                            evidence: item.evidence,
                            segments: detail.segments,
                            onSeek: { state.play(from: $0) }
                        )
                    }
                    Divider()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .sheet(item: $editing) { item in
            ActionItemEditor(item: item) { updated in
                save(updated)
                editing = nil
            } onCancel: {
                editing = nil
            }
        }
    }
}

extension ActionItemsTab {
    /// 이미 있는 항목이면 그 자리에서 고치고, 새 항목이면 뒤에 붙인다.
    func save(_ item: ActionItem) {
        let task = item.task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return }
        var updated = item
        updated.task = task
        var items = detail.note?.actionItems ?? []
        if let index = items.firstIndex(where: { $0.id == updated.id }) {
            items[index] = updated
        } else {
            items.append(updated)
        }
        state.updateActionItems(items, meetingId: detail.meeting.id)
    }

    func remove(_ item: ActionItem) {
        let items = (detail.note?.actionItems ?? []).filter { $0.id != item.id }
        state.updateActionItems(items, meetingId: detail.meeting.id)
    }
}

struct ActionItemEditor: View {
    @State private var draft: ActionItem
    let onSave: (ActionItem) -> Void
    let onCancel: () -> Void

    init(item: ActionItem, onSave: @escaping (ActionItem) -> Void, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: item)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("액션아이템 수정").font(.headline)
            Form {
                TextField("작업 내용", text: $draft.task, axis: .vertical)
                TextField(
                    "담당자 (\(UnresolvedMarker.undetermined) 상태로 두려면 비움)",
                    text: Binding(
                        get: { draft.assignee ?? "" },
                        set: { draft.assignee = $0.isEmpty ? nil : $0 }
                    )
                )
                TextField(
                    "마감일 (\(UnresolvedMarker.undetermined) 상태로 두려면 비움)",
                    text: Binding(
                        get: { draft.dueDate ?? "" },
                        set: { draft.dueDate = $0.isEmpty ? nil : $0 }
                    )
                )
                Picker("상태", selection: $draft.status) {
                    ForEach(ActionItemStatus.allCases, id: \.self) { status in
                        Text(status.displayName).tag(status)
                    }
                }
            }
            if !draft.evidence.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("근거 타임스탬프 (유지됨)").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(draft.evidence.enumerated()), id: \.offset) { _, evidence in
                        Text("\(TimeFormat.stamp(evidence.startTime)) “\(evidence.quote)”")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Spacer()
                Button("취소", action: onCancel)
                Button("저장") { onSave(draft) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 460)
    }
}
