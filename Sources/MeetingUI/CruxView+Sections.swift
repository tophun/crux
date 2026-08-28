import MeetingCore
import SwiftUI

/// CruxView의 상태별 섹션. 녹음 중 펼침(헤더·메모·컨트롤)과 접힌 상태의 좌우 날개를 그린다.
/// 본체 파일이 길어지지 않게 분리했고, 레이아웃 규칙은 `CruxView` 본문 주석을 따른다.
extension CruxView {
    // MARK: 녹음 중 펼침

    /// 상단 띠(노치 양옆 날개: 타일 · 파형) → 제목·경과 → 메모 입력 → 컨트롤.
    ///
    /// 상단 띠 높이는 접힌 캡슐과 같다. 이 띠의 가운데는 **하드웨어 노치가 실제로 가리는 영역**이라
    /// 글자를 두면 실기에서 잘려 보인다. 그래서 상단 띠에는 날개 아이콘만 두고 제목은 그 아래에 놓는다.
    func recordingExpanded(seconds: TimeInterval, paused: Bool) -> some View {
        let title = meetingTitle ?? (paused ? "녹음 일시정지" : "녹음 중")
        return VStack(alignment: .leading, spacing: 0) {
            // 상단 띠: 노치 좌우 날개
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(LinearGradient(
                        colors: [MeetingTint.color(for: title), MeetingTint.color(for: title).opacity(0.5)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 22, height: 22)
                    .overlay {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: metrics.hasNotch ? metrics.notchWidth : 10)
                Group {
                    if paused {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.orange)
                    } else {
                        // 실제 입력 레벨이 연결되기 전까지는 흉내 낸 파형이다.
                        LevelWaveform(barCount: 6, color: Self.waveformTint)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: barHeight)

            // 제목·경과: 노치 아래
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    Circle()
                        .fill(paused ? Color.orange : Color.red)
                        .frame(width: 6, height: 6)
                    Text(CruxState.clock(seconds))
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.7))
                    if !memos.isEmpty {
                        Text("· 메모 \(memos.count)")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 10)

            memoComposer

            HStack {
                controlButton(paused ? "play.fill" : "pause.fill", size: 16, help: paused ? "재개" : "일시정지", action: onTogglePause)
                controlButton("stop.fill", size: 15, help: "녹음 종료", tint: Color(red: 1, green: 0.35, blue: 0.35), action: onStop)
                Spacer()
                controlButton("macwindow", size: 14, help: "앱 열기", action: onOpenPreview)
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 메모 입력 칸과 최근 메모 두 개. Return으로 저장하고 칸을 비운다.
    var memoComposer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                TextField("메모를 적고 Return", text: $memoDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($memoFocused)
                    .onSubmit(submitMemo)
                if !memoDraft.isEmpty {
                    Button(action: submitMemo) {
                        Image(systemName: "arrow.turn.down.left")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 20, height: 20)
                            .background(.white.opacity(0.18), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("메모 저장")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(.white.opacity(memoFocused ? 0.14 : 0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .onChange(of: memoFocused) { _, focused in onMemoFocusChange(focused) }

            ForEach(memos.suffix(2).reversed()) { memo in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(memo.elapsedLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.45))
                    Text(memo.text)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                .padding(.horizontal, 4)
            }
        }
    }

    func submitMemo() {
        let text = memoDraft
        memoDraft = ""
        onAddMemo(text)
    }

    func controlButton(
        _ systemName: String,
        size: CGFloat,
        help: String,
        tint: Color = .white,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
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
