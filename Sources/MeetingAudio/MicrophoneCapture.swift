import AVFoundation
import Foundation
import MeetingCore

/// 마이크 녹음(`AVAudioEngine`).
///
/// - 권한 요청, 장치 확인, 시작·일시정지·재개·종료
/// - 장치 연결 해제(구성 변경) 시 엔진을 재시작한다
/// - 오디오는 로컬 파일로만 쓴다
public actor MicrophoneCapture {
    public struct Configuration: Sendable {
        /// 저장 샘플레이트. 음성 인식이 16kHz로 다운샘플하므로 그 값에 맞춰 저장한다.
        /// 48kHz로 저장하면 용량이 3배 가까이 늘고 인식 품질은 같다(실측 확인).
        public var sampleRate: Double
        public var channelCount: Int
        public var bitRate: Int

        public init(sampleRate: Double = 16000, channelCount: Int = 1, bitRate: Int = 32000) {
            self.sampleRate = sampleRate
            self.channelCount = channelCount
            self.bitRate = bitRate
        }
    }

    public private(set) var state: CaptureState = .idle
    public private(set) var recordedDuration: TimeInterval = 0

    private let configuration: Configuration
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var outputURL: URL?
    private var isWriting = false
    private var observer: NSObjectProtocol?
    private let log: (@Sendable (String) -> Void)?

    public init(configuration: Configuration = Configuration(), log: (@Sendable (String) -> Void)? = nil) {
        self.configuration = configuration
        self.log = log
    }

    public static func permission() -> CapturePermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    public static func requestPermission() async -> CapturePermissionState {
        if permission() == .granted {
            return .granted
        }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        return granted ? .granted : .denied
    }

    /// 입력 장치가 있는지 확인한다.
    public static func hasInputDevice() -> Bool {
        AVCaptureDevice.default(for: .audio) != nil
    }

    func start(to url: URL, captionSink: LiveAudioChunkSink? = nil) async throws {
        guard state == .idle else { throw CaptureError.invalidState(String(describing: state)) }
        guard Self.permission() == .granted else { throw CaptureError.permissionDenied("마이크") }
        guard Self.hasInputDevice() else { throw CaptureError.noInputDevice }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else { throw CaptureError.noInputDevice }

        // 입력 포맷을 그대로 쓰지 않고 16kHz 모노로 변환해 저장한다.
        // 변환 없이 파일 샘플레이트만 낮추면 길이가 어긋난 파일이 만들어진다(실측 확인).
        let targetFormat = AVAudioFormat(
            standardFormatWithSampleRate: configuration.sampleRate,
            channels: AVAudioChannelCount(configuration.channelCount)
        )
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: configuration.sampleRate,
            AVNumberOfChannelsKey: configuration.channelCount,
            AVEncoderBitRateKey: configuration.bitRate
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        self.file = file
        outputURL = url
        isWriting = true

        let sink = AudioFileSink(
            file: file,
            inputFormat: inputFormat,
            targetFormat: targetFormat,
            captionSink: captionSink
        )
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            sink.write(buffer)
        }

        // 오디오 장치가 바뀌면(연결 해제 등) 엔진을 다시 세운다.
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak sink] _ in
            sink?.markInterrupted()
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            cleanup()
            throw CaptureError.engineFailed(error.localizedDescription)
        }
        state = .recording
        log?("마이크 녹음 시작: \(url.lastPathComponent)")
    }

    public func pause() throws {
        guard state == .recording else { throw CaptureError.invalidState(String(describing: state)) }
        engine.pause()
        isWriting = false
        state = .paused
    }

    public func resume() throws {
        guard state == .paused else { throw CaptureError.invalidState(String(describing: state)) }
        do {
            try engine.start()
        } catch {
            throw CaptureError.engineFailed(error.localizedDescription)
        }
        isWriting = true
        state = .recording
    }

    /// 녹음을 끝내고 저장된 파일 정보를 돌려준다.
    public func stop() throws -> AudioFileInfo? {
        guard state == .recording || state == .paused else { return nil }
        state = .stopping
        let url = outputURL
        cleanup()
        state = .idle
        guard let url else { return nil }
        let info = try AudioFileInspector.inspect(url: url)
        recordedDuration = info.duration
        log?(String(format: "마이크 녹음 종료: %.1f초", info.duration))
        return info
    }

    private func cleanup() {
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        file = nil
        isWriting = false
    }
}

/// 탭 콜백에서 파일에 쓰는 도우미. 콜백은 실시간 스레드에서 오므로 락을 짧게 쓴다.
///
/// 입력(보통 48kHz)과 저장 포맷(16kHz 모노)이 다르면 `AVAudioConverter`로 변환한 뒤 쓴다.
final class AudioFileSink: @unchecked Sendable {
    private let file: AVAudioFile
    private let converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat?
    private let captionSink: LiveAudioChunkSink?
    private let lock = NSLock()
    private var interrupted = false

    init(
        file: AVAudioFile,
        inputFormat: AVAudioFormat,
        targetFormat: AVAudioFormat?,
        captionSink: LiveAudioChunkSink? = nil
    ) {
        self.file = file
        self.captionSink = captionSink
        if let targetFormat, targetFormat != inputFormat {
            self.targetFormat = targetFormat
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        } else {
            self.targetFormat = nil
            converter = nil
        }
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !interrupted else { return }

        guard let converter, let targetFormat else {
            try? file.write(from: buffer)
            captionSink?.write(buffer)
            return
        }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, converted.frameLength > 0 else { return }
        try? file.write(from: converted)
        captionSink?.write(converted)
    }

    func markInterrupted() {
        lock.lock()
        interrupted = true
        lock.unlock()
    }
}

public enum CaptureError: Error, LocalizedError, Sendable {
    case permissionDenied(String)
    case noInputDevice
    case invalidState(String)
    case engineFailed(String)
    case systemAudioUnavailable(String)
    case mixFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .permissionDenied(what):
            "\(what) 권한이 없어 녹음할 수 없습니다. 시스템 설정에서 권한을 허용해 주세요."
        case .noInputDevice:
            "사용할 수 있는 오디오 입력 장치가 없습니다."
        case let .invalidState(state):
            "현재 상태(\(state))에서는 할 수 없는 동작입니다."
        case let .engineFailed(message):
            "오디오 엔진을 시작할 수 없습니다: \(message)"
        case let .systemAudioUnavailable(message):
            "시스템 오디오를 캡처할 수 없습니다: \(message)"
        case let .mixFailed(message):
            "오디오 합성에 실패했습니다: \(message)"
        }
    }
}
