import AVFoundation
import Foundation
import MeetingCore
import ScreenCaptureKit

/// 시스템 오디오 캡처(`ScreenCaptureKit`).
///
/// Zoom·Google Meet·Teams 등 다른 앱이 내는 소리를 녹음한다.
/// 화면 영상은 저장하지 않고(최소 크기 프레임을 버린다) 오디오만 파일로 쓴다.
/// 권한: 시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 기록
public final class SystemAudioCapture: NSObject, SCStreamOutput, @unchecked Sendable {
    public private(set) var state: CaptureState = .idle

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var startedWriting = false
    private let queue = DispatchQueue(label: "system-audio-capture")
    private let lock = NSLock()
    private let log: (@Sendable (String) -> Void)?

    public init(log: (@Sendable (String) -> Void)? = nil) {
        self.log = log
        super.init()
    }

    /// 화면 기록 권한 상태.
    ///
    /// `SCShareableContent` 조회는 권한이 없으면 매번 시스템 대화상자를 띄우므로 쓰지 않는다.
    /// `CGPreflightScreenCaptureAccess`는 대화상자 없이 상태만 알려 준다.
    public static func permission() async -> CapturePermissionState {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    /// 화면 기록 권한을 요청한다. 시스템 대화상자를 띄울 수 있으므로 온보딩·설정에서만 부른다.
    public static func requestPermission() async -> CapturePermissionState {
        if CGPreflightScreenCaptureAccess() { return .granted }
        return CGRequestScreenCaptureAccess() ? .granted : .denied
    }

    /// - Parameter excludingCurrentProcess: 앱 자신의 소리는 녹음하지 않는다.
    public func start(to url: URL, excludingCurrentProcess: Bool = true) async throws {
        guard state == .idle else { throw CaptureError.invalidState(String(describing: state)) }

        // 권한이 없을 때 SCShareableContent를 부르면 시스템 대화상자가 뜬다.
        // 녹음 시작마다 뜨지 않도록 조용한 조회로 먼저 확인하고 건너뛴다.
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureError.systemAudioUnavailable(
                "화면 기록 권한이 없습니다. 시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 기록에서 허용하세요."
            )
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.systemAudioUnavailable(
                "화면 기록 권한이 필요합니다: \(error.localizedDescription)"
            )
        }
        guard let display = content.displays.first else {
            throw CaptureError.systemAudioUnavailable("사용할 수 있는 디스플레이가 없습니다.")
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        // 회의 음성이므로 16kHz 모노로 충분하다. 48kHz 스테레오 대비 용량이 크게 줄고
        // 음성 인식 품질은 같다(실측 확인). AVAssetWriter가 입력 포맷을 알아서 변환한다.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw CaptureError.systemAudioUnavailable("오디오 트랙을 만들 수 없습니다.")
        }
        writer.add(input)
        self.writer = writer
        audioInput = input
        outputURL = url

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = excludingCurrentProcess
        configuration.sampleRate = 48000
        configuration.channelCount = 2
        // 영상은 쓰지 않으므로 최소 크기·최저 프레임으로 둔다.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 6

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        self.stream = stream

        do {
            try await stream.startCapture()
        } catch {
            cleanup()
            throw CaptureError.systemAudioUnavailable(error.localizedDescription)
        }
        lock.withLock { state = .recording }
        log?("시스템 오디오 캡처 시작: \(url.lastPathComponent)")
    }

    public func pause() {
        lock.withLock { if state == .recording { state = .paused } }
    }

    public func resume() {
        lock.withLock { if state == .paused { state = .recording } }
    }

    public func stop() async throws -> AudioFileInfo? {
        // 1. 콜백이 더 이상 쓰지 못하도록 먼저 상태를 바꾼다.
        let started: (url: URL?, stream: SCStream?)? = lock.withLock {
            guard state == .recording || state == .paused else { return nil }
            state = .stopping
            return (outputURL, self.stream)
        }
        guard let started else { return nil }
        let url = started.url
        let stream = started.stream

        // 2. 스트림 출력을 떼고 캡처를 멈춘다. 이후에는 콜백이 오지 않는다.
        if let stream {
            try? stream.removeStreamOutput(self, type: .audio)
            try? await stream.stopCapture()
        }

        // 3. 콜백이 끝난 뒤에만 writer를 정리한다.
        let pending: (writer: AVAssetWriter?, input: AVAssetWriterInput?, didWrite: Bool) = lock.withLock {
            let snapshot = (self.writer, self.audioInput, self.startedWriting)
            self.stream = nil
            self.writer = nil
            self.audioInput = nil
            self.startedWriting = false
            return snapshot
        }
        let writer = pending.writer
        let audioInput = pending.input
        let didWrite = pending.didWrite

        if didWrite {
            audioInput?.markAsFinished()
            if let writer, writer.status == .writing {
                await writer.finishWriting()
            }
        } else {
            writer?.cancelWriting()
        }

        lock.withLock { state = .idle }

        guard didWrite, let url, FileManager.default.fileExists(atPath: url.path) else {
            log?("시스템 오디오: 저장된 샘플이 없어 파일을 만들지 않았습니다.")
            return nil
        }
        let info = try AudioFileInspector.inspect(url: url)
        log?(String(format: "시스템 오디오 캡처 종료: %.1f초", info.duration))
        return info
    }

    private func cleanup() {
        lock.withLock {
            stream = nil
            writer = nil
            audioInput = nil
            startedWriting = false
        }
    }

    // MARK: - SCStreamOutput

    public func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        lock.withLock {
            guard state == .recording, let writer, let audioInput else { return }

            if !startedWriting {
                guard writer.startWriting() else { return }
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                startedWriting = true
            }
            if audioInput.isReadyForMoreMediaData {
                audioInput.append(sampleBuffer)
            }
        }
    }
}
