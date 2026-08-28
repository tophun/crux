import AppKit
import MeetingCore
import SwiftUI

/// 새 회의 상세 상단에 지난 미완료 액션을 보여 준다. 완료 처리하지 않는다.
struct CarryoverActionsView: View {
    let actions: [CarryoverAction]
    var onOpenSource: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("지난 회의 미완료 액션 · \(actions.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(actions) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.action.task)
                            .font(.callout)
                            .textSelection(.enabled)
                        Spacer(minLength: 8)
                        if let key = item.displayJiraKey {
                            jiraBadge(key, url: item.jiraURL)
                        }
                    }
                    HStack(spacing: 10) {
                        Label(item.action.assigneeDisplay, systemImage: "person")
                        Label(item.action.dueDateDisplay, systemImage: "calendar")
                        Label(item.action.status.displayName, systemImage: "flag")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Button {
                        onOpenSource(item.sourceMeetingId)
                    } label: {
                        Text("\(item.sourceMeetingTitle) · \(item.sourceStartedAt, format: .dateTime.year().month().day())")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .help("원본 회의 열기")
                }
                if item.id != actions.last?.id {
                    Divider()
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("지난 회의 미완료 액션 \(actions.count)건")
    }

    @ViewBuilder
    private func jiraBadge(_ key: String, url: String?) -> some View {
        if let url, let link = URL(string: url) {
            Button(key) {
                NSWorkspace.shared.open(link)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .help("Jira에서 열기")
            .accessibilityLabel("Jira \(key)")
        } else {
            Text(key)
                .font(.caption.monospaced())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
                .accessibilityLabel("Jira \(key)")
        }
    }
}
