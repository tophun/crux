import MeetingCore
import SwiftUI

/// CruxView의 상태별 섹션. 녹음 중 노트(토글)와 접힌 상태의 좌우 날개를 그린다.
/// 본체 파일이 길어지지 않게 분리했고, 레이아웃 규칙은 `CruxView` 본문 주석을 따른다.
extension CruxView {
    // MARK: 녹음 중 노트

    /// 사용자가 노트를 켰을 때만 제목+본문을 보여 준다. 일시정지·종료는 위 캡슐 바에 둔다.
    var recordingNote: some View {
        let title = meetingTitle ?? "녹음 중"
        return VStack(alignment: .leading, spacing: 0) {
            noteHeader(title: title)
            noteEditor
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: seedNoteIfNeeded)
    }

    func seedNoteIfNeeded() {
        guard !didSeedNote else { return }
        didSeedNote = true
        let seeded = CruxNote.seedBody(
            note: noteBody.isEmpty ? nil : CruxNote(title: meetingTitle ?? "", body: noteBody),
            memos: memos
        )
        guard memoDraft != seeded else { return }
        suppressNoteSave = true
        memoDraft = seeded
    }

    /// 왼쪽 제목, 오른쪽 목록·Aa·고정·더보기. 고정만 기존 동작에 연결한다.
    func noteHeader(title: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            noteChromeButton("list.bullet", label: "목록")
            noteAaButton
            Button(action: onTogglePin) {
                Image(systemName: expansionMode.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(expansionMode.isPinned ? "고정 해제" : "고정")
            .accessibilityLabel(expansionMode.isPinned ? "고정 해제" : "고정")
            noteChromeButton("ellipsis.circle", label: "더보기")
        }
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    /// 시각 라벨 없는 자유 포맷 본문. 스크롤바 크롬은 숨긴다.
    var noteEditor: some View {
        TextEditor(text: $memoDraft)
            .font(.system(size: 14))
            .foregroundStyle(.white)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .focused($memoFocused)
            .padding(.horizontal, -4)
            .frame(minHeight: 132, maxHeight: 160)
            .onChange(of: memoFocused) { _, focused in onMemoFocusChange(focused) }
            .onChange(of: memoDraft) { _, text in
                if suppressNoteSave {
                    suppressNoteSave = false
                    return
                }
                onUpdateNote(text)
            }
            .accessibilityLabel("메모 본문")
    }

    var noteAaButton: some View {
        Text("Aa")
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.72))
            .frame(width: 22, height: 22)
            .accessibilityLabel("서식")
    }

    func noteChromeButton(_ systemName: String, label: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.72))
            .frame(width: 22, height: 22)
            .accessibilityLabel(label)
    }

    func draftSummaryRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("초안")
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.white.opacity(0.16), in: Capsule())
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(3)
        }
        .accessibilityLabel("초안 요약. \(text)")
    }

    // MARK: 접힌 상태

    @ViewBuilder
    var compactLeading: some View {
        switch state {
        case let .recording(_, paused):
            Circle()
                .fill(paused ? Color.orange : Color.red)
                .frame(width: 8, height: 8)
                .modifier(PulseModifier(active: !paused))
        default:
            meetingTile
        }
    }

    @ViewBuilder
    var compactTrailing: some View {
        switch state {
        case let .recording(_, paused):
            if paused {
                Image(systemName: "pause.fill")
                    .font(.system(size: 11, weight: .bold))
            } else {
                // 실제 입력 레벨이 연결되기 전까지는 흉내 낸 파형이다.
                LevelWaveform(barCount: 5, color: Self.waveformTint)
            }
        case let .generating(fraction, _):
            ProgressRing(fraction: fraction)
        case let .imminent(_, minutes):
            Text("\(minutes)분")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
        case let .previewReady(_, count):
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold))
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .frame(height: 15)
                        .background(.white.opacity(0.18), in: Capsule())
                }
            }
        case .published:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
        case .detected:
            Image(systemName: "record.circle")
                .font(.system(size: 12, weight: .semibold))
        case .hidden:
            EmptyView()
        }
    }

    /// 회의를 나타내는 작은 타일. 참고 UI의 앨범 아트 자리다. 지금은 제목 해시로 색을 정한다.
    var meetingTile: some View {
        let color = MeetingTint.color(for: presentation.title ?? state.kindId)
        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(LinearGradient(colors: [color, color.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 20, height: 20)
            .overlay {
                Image(systemName: presentation.symbolName ?? "calendar")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
            }
    }
}
