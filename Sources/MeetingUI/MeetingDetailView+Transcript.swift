import Foundation
import MeetingCore
import SwiftUI

/// 전사문 탭. 구간을 눌러 범위를 고르고 그 오디오만 다시 인식할 수 있다.
struct TranscriptTab: View {
    @Bindable var state: AppState
    let detail: MeetingDetail
    @State private var showExcluded = false
    @State private var filter = ""
    @State private var rangeStartId: UUID?
    @State private var rangeEndId: UUID?
    @State private var reextractNotes = false

    private var selectedSegments: [TranscriptSegment] {
        guard let rangeStartId, let rangeEndId else { return [] }
        return TranscriptRangePatcher.spanning(from: rangeStartId, to: rangeEndId, in: detail.segments)
    }

    private var selectedRange: TimeRange? {
        TranscriptRangePatcher.covering(selectedSegments)
    }

    private var selectedIds: Set<UUID> {
        Set(selectedSegments.map(\.id))
    }

    private var hasAudio: Bool {
        detail.tracks.contains { FileManager.default.fileExists(atPath: $0.fileURL.path) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("전사문 검색", text: $filter).textFieldStyle(.roundedBorder)
                Toggle("회의록에서 제외된 구간 보기", isOn: $showExcluded)
            }
            .padding(.horizontal).padding(.top, 8)

            if !detail.segments.isEmpty {
                Text("구간을 눌러 선택하고, 다른 구간을 눌러 범위를 넓힌 뒤 다시 전사할 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            if let selectedRange {
                selectionBar(selectedRange)
            }

            let labels = detail.relevanceBySegment
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(detail.segments) { segment in
                        let label = labels[segment.id] ?? .uncertain
                        if showExcluded || label != .exclude,
                           filter.isEmpty || segment.text.localizedCaseInsensitiveContains(filter) {
                            segmentRow(segment, label: label)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        }
        .onChange(of: detail.meeting.id) { _, _ in
            clearSelection()
        }
    }

    private func selectionBar(_ range: TimeRange) -> some View {
        HStack(spacing: 10) {
            Text("\(TimeFormat.stamp(range.start))–\(TimeFormat.stamp(range.end))")
                .font(.caption.monospacedDigit())
            Button("선택 구간 다시 전사") {
                guard let meetingRange = selectedRange else { return }
                state.retranscribeRange(
                    meetingId: detail.meeting.id,
                    startTime: meetingRange.start,
                    endTime: meetingRange.end,
                    reextractNotes: reextractNotes
                )
            }
            .disabled(state.isProcessing || !hasAudio)
            .help(hasAudio ? "선택한 구간의 오디오만 다시 인식합니다." : "오디오가 없어 다시 전사할 수 없습니다.")
            Toggle("이 구간 회의록도 다시 뽑기", isOn: $reextractNotes)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("끄면 전사문만 바뀌고 기존 근거 시각은 유지됩니다.")
            Button("선택 해제") { clearSelection() }
                .font(.caption)
            Spacer()
        }
        .padding(.horizontal)
    }

    private func segmentRow(_ segment: TranscriptSegment, label: RelevanceLabel) -> some View {
        let isPlayingSegment = state.playback.currentTime >= segment.startTime
            && state.playback.currentTime < segment.endTime
        let isSelected = selectedIds.contains(segment.id)
        return HStack(alignment: .top, spacing: 8) {
            Button {
                state.play(from: segment.startTime)
            } label: {
                Text(TimeFormat.stamp(segment.startTime))
                    .font(.caption.monospacedDigit())
                    .frame(width: 52, alignment: .leading)
            }
            .buttonStyle(.link)
            .help("이 구간부터 듣기")
            Text(segment.text)
                .foregroundStyle(label == .exclude ? .secondary : .primary)
                .textSelection(.enabled)
            Spacer()
            Text(label.rawValue)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            rowBackground(isSelected: isSelected, isPlaying: isPlayingSegment),
            in: RoundedRectangle(cornerRadius: 4)
        )
        .contentShape(Rectangle())
        .onTapGesture { select(segment) }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func rowBackground(isSelected: Bool, isPlaying: Bool) -> Color {
        if isSelected {
            return Color.accentColor.opacity(0.22)
        }
        if isPlaying {
            return Color.accentColor.opacity(0.12)
        }
        return Color.clear
    }

    private func select(_ segment: TranscriptSegment) {
        if rangeStartId == nil || rangeStartId != rangeEndId {
            rangeStartId = segment.id
            rangeEndId = segment.id
            return
        }
        rangeEndId = segment.id
    }

    private func clearSelection() {
        rangeStartId = nil
        rangeEndId = nil
        reextractNotes = false
    }
}
