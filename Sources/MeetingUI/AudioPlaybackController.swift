import AVFoundation
import MeetingCore
import Observation
import SwiftUI

/// 회의 오디오 재생.
///
/// 로컬 파일만 재생하며 네트워크를 쓰지 않는다.
/// 근거 타임스탬프를 눌러 그 지점부터 들을 수 있게 하는 것이 주 용도다.
@MainActor
@Observable
public final class AudioPlaybackController {
    public private(set) var track: AudioTrack?
    public private(set) var availableTracks: [AudioTrack] = []
    public private(set) var isPlaying = false
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var errorMessage: String?

    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?

    public init() {}

    public var isLoaded: Bool { player != nil }

    /// 회의의 트랙 목록을 받아 재생 준비를 한다. 파일이 없으면 이유를 남긴다.
    public func prepare(tracks: [AudioTrack]) {
        let previousId = track?.id
        availableTracks = tracks.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }

        guard !availableTracks.isEmpty else {
            unload()
            errorMessage = tracks.isEmpty
                ? "이 회의에는 저장된 오디오가 없습니다."
                : "원본 오디오가 삭제되어 재생할 수 없습니다."
            return
        }

        // 같은 트랙이 그대로면 재생 위치를 유지한다.
        if let previousId, let same = availableTracks.first(where: { $0.id == previousId }), player != nil {
            track = same
            return
        }
        load(AudioTrack.preferredForPlayback(availableTracks))
    }

    public func select(track: AudioTrack) {
        guard track.id != self.track?.id else { return }
        let resumeTime = currentTime
        let wasPlaying = isPlaying
        load(track)
        if duration > 0 {
            seek(to: min(resumeTime, duration), autoPlay: wasPlaying)
        }
    }

    public func playPause() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            stopTicking()
        } else {
            player.play()
            isPlaying = true
            startTicking()
        }
    }

    /// 지정한 시각으로 이동한다. 근거 타임스탬프를 눌렀을 때 쓴다.
    public func seek(to time: TimeInterval, autoPlay: Bool = true) {
        guard let player else { return }
        let target = min(max(0, time), max(0, player.duration - 0.05))
        player.currentTime = target
        currentTime = target
        if autoPlay {
            player.play()
            isPlaying = true
            startTicking()
        }
    }

    public func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds, autoPlay: isPlaying)
    }

    public func stop() {
        player?.stop()
        isPlaying = false
        currentTime = 0
        stopTicking()
    }

    public func unload() {
        stop()
        player = nil
        track = nil
        availableTracks = []
        duration = 0
        errorMessage = nil
    }

    // MARK: - 내부

    private func load(_ track: AudioTrack?) {
        stopTicking()
        guard let track else {
            player = nil
            self.track = nil
            duration = 0
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: track.fileURL)
            player.prepareToPlay()
            self.player = player
            self.track = track
            duration = player.duration
            currentTime = 0
            isPlaying = false
            errorMessage = nil
        } catch {
            self.player = nil
            self.track = nil
            duration = 0
            isPlaying = false
            errorMessage = "오디오를 열 수 없습니다: \(error.localizedDescription)"
        }
    }

    private func startTicking() {
        stopTicking()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                if !player.isPlaying, self.isPlaying {
                    // 끝까지 재생되면 처음으로 되돌린다.
                    self.isPlaying = false
                    if player.currentTime >= player.duration - 0.2 {
                        self.currentTime = 0
                        player.currentTime = 0
                    }
                    return
                }
            }
        }
    }

    private func stopTicking() {
        ticker?.cancel()
        ticker = nil
    }
}
