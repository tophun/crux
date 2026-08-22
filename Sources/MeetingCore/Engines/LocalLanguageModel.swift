import Foundation

/// 추론 방식. 사용자에게 노출되지 않고 `ReasoningRouter`가 자동으로 선택한다.
public enum ReasoningMode: String, Sendable, CaseIterable {
    case thinking
    case nonThinking
}

/// 로컬 LLM 추상화. 구현은 교체 가능하며 어떤 구현도 외부 서버를 호출하지 않는다.
public protocol LocalLanguageModel: Sendable {
    func generate(
        prompt: String,
        mode: ReasoningMode,
        maxTokens: Int
    ) async throws -> String

    /// 시스템 지시를 분리해 전달할 수 있는 경우 사용한다. 기본 구현은 프롬프트를 합친다.
    func generate(
        systemPrompt: String?,
        prompt: String,
        mode: ReasoningMode,
        maxTokens: Int
    ) async throws -> String

    /// 모델 가중치를 메모리에 올린다. 이미 로드되어 있으면 아무 것도 하지 않는다.
    func load() async throws

    /// 메모리를 해제한다. 16GB 제약에서 음성 인식 모델과 동시 상주를 막기 위해 필요하다.
    func unload() async
}

extension LocalLanguageModel {
    public func generate(
        systemPrompt: String?,
        prompt: String,
        mode: ReasoningMode,
        maxTokens: Int
    ) async throws -> String {
        let merged: String
        if let systemPrompt, !systemPrompt.isEmpty {
            merged = systemPrompt + "\n\n" + prompt
        } else {
            merged = prompt
        }
        return try await generate(prompt: merged, mode: mode, maxTokens: maxTokens)
    }

    public func load() async throws {}
    public func unload() async {}
}
