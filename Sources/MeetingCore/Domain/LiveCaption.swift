import Foundation

/// 녹음 중 자막 한 줄. Whisper 부분 결과이며 화자 구분은 하지 않는다.
public struct LiveCaptionLine: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var text: String

    public init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}

/// 녹음 화면에 보여주는 지연 자막과 초안 요약.
///
/// 요약은 전사 모델 결과만으로 짧게 만들고, 회의가 끝나 전체 파이프라인이
/// 돌기 전에는 항상 초안이다. LLM은 올리지 않는다.
public struct LiveCaptionState: Equatable, Sendable, Codable {
    public var lines: [LiveCaptionLine]
    public var draftSummary: String?
    /// 회의가 끝나 전체 파이프라인이 돌기 전에는 true.
    public var isDraft: Bool
    public var lastError: String?
    public var isActive: Bool

    public init(
        lines: [LiveCaptionLine] = [],
        draftSummary: String? = nil,
        isDraft: Bool = true,
        lastError: String? = nil,
        isActive: Bool = false
    ) {
        self.lines = lines
        self.draftSummary = draftSummary
        self.isDraft = isDraft
        self.lastError = lastError
        self.isActive = isActive
    }

    public var recentLines: [LiveCaptionLine] {
        Array(lines.suffix(3))
    }

    /// 창 갱신 비교용. 자막이 늘거나 초안이 바뀌면 값이 달라진다.
    public var fingerprint: String {
        "\(lines.count)|\(lines.last?.text ?? "")|\(draftSummary ?? "")|\(lastError ?? "")|\(isActive)"
    }

    /// 개발용 캡슐 미리보기에 쓰는 고정 자막.
    public static let demo = LiveCaptionState(
        lines: [
            LiveCaptionLine(startTime: 732, endTime: 740, text: "결제 모듈 배포는 3월 12일로 확정합니다."),
            LiveCaptionLine(startTime: 741, endTime: 748, text: "체크리스트는 다음 주 월요일까지 공유해 주세요.")
        ],
        draftSummary: "배포일을 3월 12일로 정하고 체크리스트를 공유하기로 했다.",
        isDraft: true,
        isActive: true
    )
}

/// 자막에서 짧은 초안 요약을 만든다. LLM을 부르지 않는다.
public enum LiveDraftSummaryBuilder {
    /// 앞에서부터 이어 붙이고, 한도를 넘으면 잘라 초안임을 드러낸다.
    public static func make(from segments: [TranscriptSegment], maxCharacters: Int = 160) -> String {
        make(from: segments.map(\.text), maxCharacters: maxCharacters)
    }

    public static func make(from lines: [LiveCaptionLine], maxCharacters: Int = 160) -> String {
        make(from: lines.map(\.text), maxCharacters: maxCharacters)
    }

    public static func make(from texts: [String], maxCharacters: Int = 160) -> String {
        let parts = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty, maxCharacters > 0 else { return "" }

        let joined = parts.joined(separator: " ")
        if joined.count <= maxCharacters {
            return joined
        }
        let clipped = String(joined.prefix(maxCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clipped + "…"
    }
}

/// 녹음 중 Whisper에 넘길, 이미 닫힌 오디오 조각.
public struct LiveAudioChunk: Sendable, Equatable {
    public var url: URL
    /// 회의 시작 기준 이 조각의 시작 시각.
    public var startOffset: TimeInterval
    public var duration: TimeInterval

    public init(url: URL, startOffset: TimeInterval, duration: TimeInterval = 0) {
        self.url = url
        self.startOffset = startOffset
        self.duration = duration
    }
}

/// 녹음이 만든 오디오 조각을 자막 세션에 건넨다.
///
/// 구현이 실패하거나 조각이 없어도 녹음은 계속된다.
public protocol LiveCaptionAudioProviding: Sendable {
    func nextCaptionChunks() async -> [LiveAudioChunk]
    func finishCaptionChunks() async -> [LiveAudioChunk]
}

public extension LiveCaptionAudioProviding {
    func finishCaptionChunks() async -> [LiveAudioChunk] {
        []
    }
}
