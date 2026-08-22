import MeetingCore
import SwiftUI

/// 회의 오디오 재생 카드. 회의 상세 화면 위쪽에 둔다.
///
/// 음성 메모와 같은 구성이다 — 왼쪽에 제목·날짜·길이, 오른쪽에 재생 조작.
/// 멈춰 있을 때는 `재생` 하나만 두고, 재생 중에만 15초 이동과 일시정지를 보여 준다.
/// 조작이 적을수록 무엇을 눌러야 할지 한눈에 들어온다.
public struct AudioPlayerBar: View {
    @Bindable var playback: AudioPlaybackController
    /// 카드에 보여 줄 제목과 날짜. 회의 정보를 그대로 쓴다.
    let title: String
    let recordedAt: Date?
    /// 처리 상태. 카드 안에 뱃지로 보여 준다.
    let status: MeetingStatus?
    /// 제목 자리를 대신할 뷰(제목 편집 칸 등). 있으면 title 문자열 대신 쓴다.
    let titleView: AnyView?

    public init(
        playback: AudioPlaybackController,
        title: String = "녹음",
        recordedAt: Date? = nil,
        status: MeetingStatus? = nil,
        titleView: AnyView? = nil
    ) {
        self.playback = playback
        self.title = title
        self.recordedAt = recordedAt
        self.status = status
        self.titleView = titleView
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    if let titleView {
                        titleView
                    } else {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                    }
                    if let status {
                        StatusBadge(status: status)
                    }
                }
                if let recordedAt {
                    Text(recordedAt, format: .dateTime.year().month().day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(subtitle)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            controls
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .quaternarySystemFill), in: RoundedRectangle(cornerRadius: 12))
    }

    /// 아래줄 문구. 멈춰 있으면 전체 길이, 재생 중이면 현재 위치와 전체 길이를 보여 준다.
    private var subtitle: String {
        guard playback.isLoaded else {
            return playback.errorMessage ?? "재생할 오디오가 없습니다"
        }
        if playback.isPlaying || playback.currentTime > 0 {
            return "\(TimeFormat.stamp(playback.currentTime)) / \(TimeFormat.stamp(playback.duration))"
        }
        return "오디오 · \(TimeFormat.stamp(playback.duration))"
    }

    @ViewBuilder
    private var controls: some View {
        if playback.isPlaying || playback.currentTime > 0 {
            HStack(spacing: 14) {
                SkipButton(symbol: "gobackward.15") { playback.skip(by: -15) }
                Button {
                    playback.playPause()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 17))
                        .frame(width: 20)
                }
                .buttonStyle(.plain)
                .help(playback.isPlaying ? "일시정지" : "재생")
                SkipButton(symbol: "goforward.15") { playback.skip(by: 15) }
            }
            .disabled(!playback.isLoaded)
        } else {
            Button {
                playback.playPause()
            } label: {
                Label("재생", systemImage: "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
            .overlay(Capsule().stroke(.separator))
            .disabled(!playback.isLoaded)
        }
    }
}

/// 15초 이동 버튼.
private struct SkipButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

/// 트랙이 여러 개일 때만 쓰는 선택기. 보통은 합성본 하나뿐이라 숨는다.
struct AudioTrackPicker: View {
    @Bindable var playback: AudioPlaybackController

    var body: some View {
        if playback.availableTracks.count > 1 {
            Picker("", selection: Binding(
                get: { playback.track?.id ?? playback.availableTracks[0].id },
                set: { id in
                    if let track = playback.availableTracks.first(where: { $0.id == id }) {
                        playback.select(track: track)
                    }
                }
            )) {
                ForEach(playback.availableTracks) { track in
                    Text(track.displayName).tag(track.id)
                }
            }
            .labelsHidden()
            .frame(width: 130)
        }
    }
}
