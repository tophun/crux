import Foundation
import MeetingCore

/// 음성 인식 모델과 LLM을 **동시에 메모리에 올리지 않는다**(§12).
///
/// 두 엔진의 로드/해제 순서를 이 액터가 독점적으로 관리한다.
/// 개발 장비의 메모리가 넉넉해도 규칙이 깨지지 않도록 구조로 강제한다.
public actor ModelLifecycleCoordinator {
    public enum Resident: String, Sendable {
        case none
        case transcription
        case languageModel
    }

    private let transcriptionEngine: any TranscriptionEngine
    private let languageModel: any LocalLanguageModel
    private var resident: Resident = .none
    private let log: (@Sendable (String) -> Void)?

    public init(
        transcriptionEngine: any TranscriptionEngine,
        languageModel: any LocalLanguageModel,
        log: (@Sendable (String) -> Void)? = nil
    ) {
        self.transcriptionEngine = transcriptionEngine
        self.languageModel = languageModel
        self.log = log
    }

    public var residentModel: Resident {
        resident
    }

    public func withTranscription<T: Sendable>(
        _ body: sending (any TranscriptionEngine) async throws -> T
    ) async throws -> T {
        if resident == .languageModel {
            log?("LLM 해제 후 음성 인식 모델 로드")
            await languageModel.unload()
            resident = .none
        }
        if resident != .transcription {
            try await transcriptionEngine.load()
            resident = .transcription
            log?("음성 인식 모델 로드 완료")
        }
        return try await body(transcriptionEngine)
    }

    public func withLanguageModel<T: Sendable>(
        _ body: sending (any LocalLanguageModel) async throws -> T
    ) async throws -> T {
        if resident == .transcription {
            log?("음성 인식 모델 해제 후 LLM 로드")
            await transcriptionEngine.unload()
            resident = .none
        }
        if resident != .languageModel {
            try await languageModel.load()
            resident = .languageModel
            log?("LLM 로드 완료")
        }
        return try await body(languageModel)
    }

    /// 처리가 끝나면 모든 모델을 내린다.
    public func releaseAll() async {
        switch resident {
        case .transcription: await transcriptionEngine.unload()
        case .languageModel: await languageModel.unload()
        case .none: break
        }
        resident = .none
        log?("모든 모델 해제")
    }
}
