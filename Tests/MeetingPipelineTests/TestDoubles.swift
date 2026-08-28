import AVFoundation
import Foundation
import MeetingCore

/// 두 모델이 동시에 메모리에 올라가지 않는지 감시한다(§12).
actor ModelResidencyMonitor {
    private(set) var events: [String] = []
    private(set) var transcriptionLoaded = false
    private(set) var languageLoaded = false
    private(set) var violated = false

    func record(_ event: String) {
        events.append(event)
        switch event {
        case "transcription.load": transcriptionLoaded = true
        case "transcription.unload": transcriptionLoaded = false
        case "language.load": languageLoaded = true
        case "language.unload": languageLoaded = false
        default: break
        }
        if transcriptionLoaded, languageLoaded {
            violated = true
        }
    }

    func snapshot() -> (events: [String], violated: Bool) {
        (events, violated)
    }
}

/// 오디오 없이 정해진 전사 결과를 돌려주는 엔진.
actor FakeTranscriptionEngine: TranscriptionEngine {
    private let monitor: ModelResidencyMonitor?
    private let segments: @Sendable (UUID) -> [TranscriptSegment]
    private let failure: (any Error)?
    private let delay: Duration?
    private(set) var transcribeCount = 0
    private(set) var transcribedURLs: [URL] = []
    private(set) var transcribedDurations: [TimeInterval] = []

    init(
        monitor: ModelResidencyMonitor? = nil,
        failure: (any Error)? = nil,
        delay: Duration? = nil,
        segments: @escaping @Sendable (UUID) -> [TranscriptSegment]
    ) {
        self.monitor = monitor
        self.failure = failure
        self.delay = delay
        self.segments = segments
    }

    func transcribe(
        audioURL: URL,
        meetingId: UUID,
        language _: String,
        progress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> [TranscriptSegment] {
        transcribeCount += 1
        transcribedURLs.append(audioURL)
        if let file = try? AVAudioFile(forReading: audioURL), file.processingFormat.sampleRate > 0 {
            transcribedDurations.append(Double(file.length) / file.processingFormat.sampleRate)
        }
        if let delay {
            try await Task.sleep(for: delay)
        }
        if let failure {
            throw failure
        }
        let result = segments(meetingId)
        progress?(
            TranscriptionProgress(processedSeconds: 60, totalSeconds: 60, segmentCount: result.count)
        )
        return result
    }

    func load() async throws {
        await monitor?.record("transcription.load")
    }

    func unload() async {
        await monitor?.record("transcription.unload")
    }

    func callCount() -> Int {
        transcribeCount
    }

    func recordedURLs() -> [URL] {
        transcribedURLs
    }

    func recordedDurations() -> [TimeInterval] {
        transcribedDurations
    }
}

/// 정해진 JSON을 돌려주는 가짜 LLM.
actor ScriptedLanguageModel: LocalLanguageModel {
    private let monitor: ModelResidencyMonitor?
    private let responder: @Sendable (String, ReasoningMode) -> String
    private(set) var generateCount = 0

    init(monitor: ModelResidencyMonitor? = nil, responder: @escaping @Sendable (String, ReasoningMode) -> String) {
        self.monitor = monitor
        self.responder = responder
    }

    func generate(prompt: String, mode: ReasoningMode, maxTokens _: Int) async throws -> String {
        generateCount += 1
        return responder(prompt, mode)
    }

    func load() async throws {
        await monitor?.record("language.load")
    }

    func unload() async {
        await monitor?.record("language.unload")
    }

    func callCount() -> Int {
        generateCount
    }
}

enum TestAudio {
    /// AVAudioFile로 실제 재생 가능한 짧은 오디오 파일을 만든다.
    static func makeSilentFile(seconds: Double = 1.0, directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("\(UUID().uuidString).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(16000 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        // 완전한 무음 대신 아주 작은 신호를 넣어 길이가 0으로 판정되지 않게 한다.
        if let channel = buffer.floatChannelData?[0] {
            for frame in 0 ..< Int(frames) {
                channel[frame] = Float(sin(Double(frame) * 0.01)) * 0.01
            }
        }
        try file.write(from: buffer)
        return url
    }

    /// 오디오로 읽을 수 없는 손상 파일.
    static func makeCorruptFile(directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("\(UUID().uuidString).m4a")
        try Data("이건 오디오가 아닙니다".utf8).write(to: url)
        return url
    }
}

enum TestScripts {
    static func segments(meetingId: UUID) -> [TranscriptSegment] {
        [
            TranscriptSegment(
                meetingId: meetingId, index: 0, startTime: 0, endTime: 8,
                text: "안녕하세요. 오늘 날씨가 참 좋네요.", confidence: 0.9
            ),
            TranscriptSegment(
                meetingId: meetingId, index: 1, startTime: 8, endTime: 16,
                text: "결제 모듈 배포는 3월 12일 수요일로 확정합니다.", confidence: 0.95
            ),
            TranscriptSegment(
                meetingId: meetingId, index: 2, startTime: 16, endTime: 24,
                text: "홍길동 님이 배포 체크리스트를 다음 주 월요일까지 공유해 주세요.", confidence: 0.93
            )
        ]
    }

    /// 프롬프트 종류에 맞는 최소 응답
    static let responder: @Sendable (String, ReasoningMode) -> String = { prompt, _ in
        if prompt.contains("segmentRelevance") {
            return """
            {"topics": [{"title": "배포 일정", "summary": "3월 배포"}],
             "decisions": [{"content": "결제 모듈 배포를 3월 12일로 확정", "kind": "decided", "confidence": 0.95,
               "evidence": [{"segment": "S1", "quote": "3월 12일 수요일로 확정합니다"}]}],
             "actionItems": [{"task": "배포 체크리스트 공유", "assignee": "홍길동", "dueDate": null,
               "dueDateNote": "다음 주 월요일", "confidence": 0.9,
               "evidence": [{"segment": "S2", "quote": "다음 주 월요일까지 공유해 주세요"}]}],
             "risks": [], "openQuestions": [],
             "segmentRelevance": [{"segment": "S0", "label": "EXCLUDE"}, {"segment": "S1", "label": "KEEP"},
               {"segment": "S2", "label": "KEEP"}]}
            """
        }
        if prompt.contains("재검토가 필요한 이유") {
            return """
            {"verdict": "confirm", "content": "배포 체크리스트 공유", "assignee": "홍길동",
             "dueDate": null, "dueDateNote": "다음 주 월요일", "confidence": 0.9,
             "evidence": [{"segment": "S2", "quote": "다음 주 월요일까지 공유해 주세요"}]}
            """
        }
        if prompt.contains("evidenceIndex") {
            return """
            {"title": "결제 모듈 배포 회의", "summary": "배포일을 3월 12일로 확정했다.",
             "decisions": [{"content": "결제 모듈 배포를 3월 12일로 확정", "kind": "decided", "evidenceIndex": 1}],
             "actionItems": [{"task": "배포 체크리스트 공유", "assignee": "홍길동", "dueDate": null,
               "status": "confirmed", "evidenceIndex": 1}],
             "openQuestions": [], "risks": [], "topics": [{"title": "배포 일정", "summary": "3월 배포"}]}
            """
        }
        return "{}"
    }
}

/// 진행률을 스레드 안전하게 모으는 도우미
final class FractionCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    func append(_ value: Double) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    func values() -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
