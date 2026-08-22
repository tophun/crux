import Foundation

/// 음성 인식 결과 한 구간. 회의록의 모든 근거는 이 구간을 가리킨다.
public struct TranscriptSegment: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var meetingId: UUID
    /// 회의 내 순서 (0부터). 프롬프트에서 쓰는 짧은 식별자 `S{index}`의 기준.
    public var index: Int
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var speakerId: String?
    public var text: String
    /// 0...1 로 정규화된 전사 신뢰도. 낮으면 사고 모드 재검토 신호가 된다.
    public var confidence: Double?
    public var sourceTrack: AudioTrackKind

    public init(
        id: UUID = UUID(),
        meetingId: UUID,
        index: Int,
        startTime: TimeInterval,
        endTime: TimeInterval,
        speakerId: String? = nil,
        text: String,
        confidence: Double? = nil,
        sourceTrack: AudioTrackKind = .mixed
    ) {
        self.id = id
        self.meetingId = meetingId
        self.index = index
        self.startTime = startTime
        self.endTime = endTime
        self.speakerId = speakerId
        self.text = text
        self.confidence = confidence
        self.sourceTrack = sourceTrack
    }

    public var duration: TimeInterval { max(0, endTime - startTime) }

    /// 프롬프트와 LLM 응답에서 사용하는 짧은 식별자. UUID는 토큰 낭비와 오탈자 위험이 커서 쓰지 않는다.
    public var shortId: String { "S\(index)" }
}

/// 결정사항·액션아이템이 원문에 실제로 존재함을 보이는 근거.
public struct Evidence: Hashable, Sendable, Codable {
    /// 전사 세그먼트 UUID 문자열. 검증에 실패한 근거는 저장하지 않는다.
    public var segmentId: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    /// 원문에서 발췌한 인용. 모델이 만들어낸 문장이면 검증 단계에서 걸러진다.
    public var quote: String

    public init(segmentId: String, startTime: TimeInterval, endTime: TimeInterval, quote: String) {
        self.segmentId = segmentId
        self.startTime = startTime
        self.endTime = endTime
        self.quote = quote
    }
}
