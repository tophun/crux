import Foundation

/// 오디오 보관 기간. 전사문·회의록·근거는 이 정책과 무관하게 영구 보관한다(§11).
///
/// 회의 오디오는 한 시간에 13MB 남짓이지만 회의가 쌓이면 디스크를 잠식한다.
/// 다른 회의록 도구도 대부분 오디오만 따로 지운다(Granola는 전사 직후 삭제,
/// Fireflies는 보관 기간 설정, Otter는 수동 삭제).
public enum AudioRetention: String, Codable, Sendable, CaseIterable {
    /// 회의록이 만들어지면 오디오를 남기지 않는다.
    case immediate
    case days7
    case days30
    case days90
    /// 사용자가 직접 지울 때까지 보관한다.
    case forever

    /// 보관 일수. `nil`이면 자동 삭제하지 않는다.
    public var days: Int? {
        switch self {
        case .immediate: 0
        case .days7: 7
        case .days30: 30
        case .days90: 90
        case .forever: nil
        }
    }

    public var label: String {
        switch self {
        case .immediate: "회의록 생성 직후"
        case .days7: "7일"
        case .days30: "30일"
        case .days90: "90일"
        case .forever: "계속 보관"
        }
    }

    public var detail: String {
        switch self {
        case .immediate: "회의록이 만들어지면 오디오를 바로 지웁니다. 다시 들을 수 없습니다."
        case .days7: "7일이 지난 회의의 오디오를 휴지통으로 보냅니다."
        case .days30: "30일이 지난 회의의 오디오를 휴지통으로 보냅니다."
        case .days90: "90일이 지난 회의의 오디오를 휴지통으로 보냅니다."
        case .forever: "직접 지울 때까지 오디오를 보관합니다."
        }
    }
}

/// 오디오 정리 규칙. 순수 계산만 하고 파일은 건드리지 않는다.
public struct AudioRetentionPolicy: Hashable, Sendable, Codable {
    public var retention: AudioRetention
    /// 회의록 생성에 성공하면 원본 트랙(마이크·시스템)을 지우고 합성본만 남긴다.
    /// 합성본은 원본을 그대로 담고 있어 재생·재처리에 충분하다.
    public var discardRawAfterProcessing: Bool

    public init(retention: AudioRetention = .days30, discardRawAfterProcessing: Bool = true) {
        self.retention = retention
        self.discardRawAfterProcessing = discardRawAfterProcessing
    }

    /// 기본값. 사용자가 설정에서 바꾸기 전까지 이 값을 쓴다.
    public static let standard = AudioRetentionPolicy()
    /// 아무것도 지우지 않는다. 테스트와 "계속 보관" 설정에 쓴다.
    public static let keepEverything = AudioRetentionPolicy(retention: .forever, discardRawAfterProcessing: false)

    /// 회의록 생성 직후에 할 일.
    public enum PostProcessingAction: Hashable, Sendable {
        /// 아무것도 지우지 않는다.
        case keep
        /// 원본 트랙만 지우고 합성본은 남긴다.
        case discardRaw
        /// 오디오를 전부 지운다.
        case discardAll
    }

    public func actionAfterProcessing() -> PostProcessingAction {
        if retention == .immediate {
            return .discardAll
        }
        return discardRawAfterProcessing ? .discardRaw : .keep
    }

    /// 자동 삭제 대상 회의. 판단에 필요한 값만 담는다.
    public struct Candidate: Hashable, Sendable {
        public var meetingId: UUID
        /// 보관 기간을 재는 기준 시각. 종료 시각이 없으면 생성 시각을 쓴다.
        public var referenceDate: Date
        /// 회의록 생성까지 끝났는지. 끝나지 않았으면 오디오가 유일한 재시도 수단이라 지우지 않는다.
        public var isCompleted: Bool
        /// 저장된 오디오가 있는지.
        public var hasAudio: Bool

        public init(meetingId: UUID, referenceDate: Date, isCompleted: Bool, hasAudio: Bool) {
            self.meetingId = meetingId
            self.referenceDate = referenceDate
            self.isCompleted = isCompleted
            self.hasAudio = hasAudio
        }
    }

    /// 보관 기간이 지난 회의를 고른다.
    ///
    /// - 회의록이 완성되지 않은 회의는 절대 고르지 않는다.
    /// - `forever`는 아무것도 고르지 않는다.
    /// - 경계는 "기준 시각 + 보관 일수 <= 지금"이다. 정확히 30일째면 지운다.
    public func expired(among candidates: [Candidate], now: Date) -> [UUID] {
        guard let days = retention.days else { return [] }
        let window = TimeInterval(days) * 86400
        return candidates
            .filter { $0.isCompleted && $0.hasAudio }
            .filter { $0.referenceDate.addingTimeInterval(window) <= now }
            .map(\.meetingId)
    }
}
