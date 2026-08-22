import AVFoundation
import Foundation
import MeetingCore

/// 마이크와 시스템 오디오를 함께 녹음하고 트랙을 분리 저장한다(§5).
///
///     meeting/
///       raw/microphone.m4a
///       raw/system.m4a
///       mixed/meeting.m4a   ← 전사에 사용
public actor MeetingAudioCapture: AudioCaptureService {
    private let microphone: MicrophoneCapture
    private let systemAudio: SystemAudioCapture
    private let log: (@Sendable (String) -> Void)?

    private var currentMeetingId: UUID?
    private var currentStorage: MeetingStorage?
    private var startedAt: Date?
    private var pausedDuration: TimeInterval = 0
    private var pausedAt: Date?
    private var systemAudioActive = false
    private var captureState: CaptureState = .idle
    /// 캡처 중 발생한 문제 (권한 거부, 장치 없음 등). 사용자에게 그대로 알린다.
    public private(set) var problems: [String] = []

    public init(
        microphone: MicrophoneCapture = MicrophoneCapture(),
        systemAudio: SystemAudioCapture = SystemAudioCapture(),
        log: (@Sendable (String) -> Void)? = nil
    ) {
        self.microphone = microphone
        self.systemAudio = systemAudio
        self.log = log
    }

    public var state: CaptureState {
        get async { captureState }
    }

    /// 녹음 경과 시간 (일시정지 시간 제외)
    public var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        let now = pausedAt ?? Date()
        return max(0, now.timeIntervalSince(startedAt) - pausedDuration)
    }

    public func microphonePermission() async -> CapturePermissionState {
        MicrophoneCapture.permission()
    }

    public func systemAudioPermission() async -> CapturePermissionState {
        await SystemAudioCapture.permission()
    }

    /// 시스템 오디오 권한을 요청한다. 시스템 대화상자를 띄울 수 있어 사용자 동작에서만 부른다.
    public func requestSystemAudioPermission() async -> CapturePermissionState {
        await SystemAudioCapture.requestPermission()
    }

    public func requestPermissions() async -> (microphone: CapturePermissionState, systemAudio: CapturePermissionState) {
        let mic = await MicrophoneCapture.requestPermission()
        let system = await SystemAudioCapture.requestPermission()
        return (mic, system)
    }

    public func start(meetingId: UUID, storage: MeetingStorage) async throws {
        guard captureState == .idle else { throw CaptureError.invalidState(String(describing: captureState)) }
        try storage.createDirectories()
        problems = []

        // 마이크는 필수다. 실패하면 녹음을 시작하지 않는다.
        try await microphone.start(to: storage.url(for: .microphone, extension: "m4a"))

        // 시스템 오디오는 권한이 없으면 마이크만으로 계속한다.
        do {
            try await systemAudio.start(to: storage.url(for: .system, extension: "m4a"))
            systemAudioActive = true
        } catch {
            systemAudioActive = false
            problems.append("시스템 오디오 없이 마이크만 녹음합니다: \(error.localizedDescription)")
            log?("시스템 오디오 캡처 실패: \(error.localizedDescription)")
        }

        currentMeetingId = meetingId
        currentStorage = storage
        startedAt = Date()
        pausedDuration = 0
        pausedAt = nil
        captureState = .recording
    }

    public func pause() async throws {
        guard captureState == .recording else { throw CaptureError.invalidState(String(describing: captureState)) }
        try await microphone.pause()
        if systemAudioActive {
            systemAudio.pause()
        }
        pausedAt = Date()
        captureState = .paused
    }

    public func resume() async throws {
        guard captureState == .paused else { throw CaptureError.invalidState(String(describing: captureState)) }
        try await microphone.resume()
        if systemAudioActive {
            systemAudio.resume()
        }
        if let pausedAt {
            pausedDuration += Date().timeIntervalSince(pausedAt)
        }
        pausedAt = nil
        captureState = .recording
    }

    public func stop() async throws -> [AudioTrack] {
        guard captureState == .recording || captureState == .paused else { return [] }
        guard let meetingId = currentMeetingId, let storage = currentStorage else { return [] }
        captureState = .stopping

        var tracks: [AudioTrack] = []
        var inputs: [URL] = []

        if let info = try? await microphone.stop() {
            tracks.append(Self.track(meetingId: meetingId, kind: .microphone, info: info))
            inputs.append(info.url)
        } else {
            problems.append("마이크 녹음 파일을 저장하지 못했습니다.")
        }

        if systemAudioActive {
            if let info = try? await systemAudio.stop() {
                tracks.append(Self.track(meetingId: meetingId, kind: .system, info: info))
                inputs.append(info.url)
            } else {
                problems.append("시스템 오디오 파일을 저장하지 못했습니다.")
            }
        }

        // 엔진이 파일을 닫지 못했더라도 디스크에 남은 녹음은 살린다.
        if tracks.isEmpty {
            let salvaged = Self.salvageTracks(meetingId: meetingId, storage: storage)
            if !salvaged.isEmpty {
                problems.append("녹음 종료 처리에 실패했지만 저장된 파일 \(salvaged.count)개를 회수했습니다.")
                tracks += salvaged
                inputs += salvaged.filter { $0.kind != .mixed }.map(\.fileURL)
                log?("녹음 파일 회수: \(salvaged.map(\.kind.rawValue).joined(separator: ", "))")
            }
        }

        // 전사에 쓸 mixed 트랙을 만든다. 원본 트랙은 그대로 남긴다.
        if !inputs.isEmpty {
            do {
                let mixedInfo = try await AudioMixer.mix(
                    inputs: inputs,
                    output: storage.url(for: .mixed, extension: "m4a")
                )
                tracks.append(Self.track(meetingId: meetingId, kind: .mixed, info: mixedInfo))
            } catch {
                problems.append("mixed 오디오를 만들지 못해 원본 트랙으로 전사합니다: \(error.localizedDescription)")
            }
        }

        currentMeetingId = nil
        currentStorage = nil
        startedAt = nil
        pausedAt = nil
        systemAudioActive = false
        captureState = .idle
        return tracks
    }

    /// 디스크에 남아 있는 녹음 파일을 찾아 트랙으로 만든다.
    ///
    /// 캡처 종료가 실패해도 이미 기록된 오디오를 잃지 않기 위한 마지막 수단이다.
    static func salvageTracks(meetingId: UUID, storage: MeetingStorage) -> [AudioTrack] {
        let candidates: [(AudioTrackKind, URL)] = [
            (.mixed, storage.url(for: .mixed, extension: "m4a")),
            (.microphone, storage.url(for: .microphone, extension: "m4a")),
            (.system, storage.url(for: .system, extension: "m4a"))
        ]
        return candidates.compactMap { kind, url in
            guard FileManager.default.fileExists(atPath: url.path),
                  let info = try? AudioFileInspector.inspect(url: url),
                  info.duration > 0.5
            else { return nil }
            return track(meetingId: meetingId, kind: kind, info: info)
        }
    }

    static func track(meetingId: UUID, kind: AudioTrackKind, info: AudioFileInfo) -> AudioTrack {
        AudioTrack(
            meetingId: meetingId,
            kind: kind,
            fileURL: info.url,
            duration: info.duration,
            sampleRate: info.sampleRate,
            channelCount: info.channelCount,
            byteSize: info.byteSize
        )
    }
}
