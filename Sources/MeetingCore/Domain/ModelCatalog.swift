import Foundation

/// 사용자가 고를 수 있는 모델 한 가지.
///
/// 목록은 앱이 검증한 것만 담는다. 임의의 모델 이름을 직접 입력하게 두지 않는다.
/// 잘못된 이름은 처리 도중에야 실패하고, 그때는 이미 녹음이 끝난 뒤라 되돌리기 어렵다.
public struct ModelChoice: Identifiable, Sendable, Hashable {
    /// 모델 식별자. 엔진에 그대로 넘긴다.
    public let id: String
    /// 화면에 보여 줄 이름
    public let name: String
    /// 무엇이 다른지 한 줄 설명. 속도와 품질의 맞바꿈을 적는다.
    public let detail: String
    /// 처음 쓸 때 내려받는 크기(GB). 사용자가 기다릴 시간을 가늠하는 근거다.
    public let downloadSizeGB: Double
    /// 이 모델을 쓰려면 필요한 최소 메모리(GB).
    public let minimumMemoryGB: Int

    public init(
        id: String,
        name: String,
        detail: String,
        downloadSizeGB: Double,
        minimumMemoryGB: Int
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.downloadSizeGB = downloadSizeGB
        self.minimumMemoryGB = minimumMemoryGB
    }

    /// 이 기기에서 쓸 수 있는지. 메모리가 모자라면 고를 수 없게 막는다.
    public func fits(memoryGB: Int = ModelChoice.physicalMemoryGB) -> Bool {
        memoryGB >= minimumMemoryGB
    }

    /// 이 기기의 물리 메모리(GB).
    public static var physicalMemoryGB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
    }
}

/// 음성 인식 모델 목록(WhisperKit).
///
/// Whisper 계열의 최신은 OpenAI가 2024-09-30에 낸 large-v3-turbo(`v20240930`)다.
/// turbo는 디코더를 줄여 빠른 대신 정확도가 조금 낮고, 원본 large-v3는 그 반대다.
public enum TranscriptionModelCatalog {
    public static let defaultId = "openai_whisper-large-v3-v20240930_turbo"

    public static let all: [ModelChoice] = [
        ModelChoice(
            id: "openai_whisper-large-v3-v20240930_626MB",
            name: "large-v3 turbo (경량)",
            detail: "가장 빠르고 가볍습니다. 정확도는 조금 낮습니다.",
            downloadSizeGB: 0.6,
            minimumMemoryGB: 8
        ),
        ModelChoice(
            id: defaultId,
            name: "large-v3 turbo",
            detail: "속도와 정확도의 균형이 좋습니다. 기본값입니다.",
            downloadSizeGB: 1.6,
            minimumMemoryGB: 8
        ),
        ModelChoice(
            id: "openai_whisper-large-v3_turbo",
            name: "large-v3",
            detail: "가장 정확합니다. 전사 시간이 2~3배 늘어납니다.",
            downloadSizeGB: 3.2,
            minimumMemoryGB: 16
        ),
    ]

    /// 저장된 값이 목록에 없으면 기본값으로 돌린다. 앱 갱신으로 목록이 바뀌어도 안전하다.
    public static func resolve(_ stored: String?) -> String {
        guard let stored, all.contains(where: { $0.id == stored }) else { return defaultId }
        return stored
    }

    public static func choice(for id: String) -> ModelChoice? {
        all.first { $0.id == id }
    }
}

/// 회의록 생성 모델 목록(MLX).
///
/// 파이프라인이 사고 모드를 켜고 끄므로(`enable_thinking`) **원본 Qwen3 계열만** 담는다.
/// `Instruct-2507` 같은 파생 계열은 이 전환을 지원하지 않아 목록에 넣지 않는다.
public enum LanguageModelCatalog {
    public static let defaultId = "mlx-community/Qwen3-8B-4bit"

    public static let all: [ModelChoice] = [
        ModelChoice(
            id: "mlx-community/Qwen3-4B-4bit",
            name: "Qwen3 4B",
            detail: "가장 빠릅니다. 긴 회의에서는 지시를 놓칠 수 있습니다.",
            downloadSizeGB: 2.3,
            minimumMemoryGB: 8
        ),
        ModelChoice(
            id: defaultId,
            name: "Qwen3 8B",
            detail: "속도와 품질의 균형이 좋습니다. 기본값입니다.",
            downloadSizeGB: 4.6,
            minimumMemoryGB: 16
        ),
        ModelChoice(
            id: "mlx-community/Qwen3-14B-4bit",
            name: "Qwen3 14B",
            detail: "요약과 표 정리가 더 정확합니다. 생성 시간이 약 2배입니다.",
            downloadSizeGB: 8.3,
            minimumMemoryGB: 16
        ),
    ]

    public static func resolve(_ stored: String?) -> String {
        guard let stored, all.contains(where: { $0.id == stored }) else { return defaultId }
        return stored
    }

    public static func choice(for id: String) -> ModelChoice? {
        all.first { $0.id == id }
    }
}
