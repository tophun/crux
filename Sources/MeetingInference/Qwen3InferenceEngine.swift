import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MeetingCore
import Tokenizers

/// MLX Swift 기반 로컬 LLM 엔진(§7).
///
/// - 기본 모델은 사고 모드 전환이 가능한 원본 `Qwen3-8B`의 4-bit 양자화판이다.
///   4B보다 지시 이행이 안정적이고, ASR과 동시 상주하지 않으므로 16GB에서 안전하다.
///   (`Instruct-2507` 계열이 아니다 — 사고 모드 전환이 필요하다.)
/// - 사고 모드는 채팅 템플릿 인자 `enable_thinking`으로 켜고 끈다. 사용자에게 노출되지 않는다.
/// - `<think>...</think>` 내부 내용은 파이프라인에서 제거되며 저장되지 않는다.
/// - 모델 가중치와 추론 상태는 이 기기를 벗어나지 않는다. 네트워크는 모델 최초 다운로드에만 쓴다.
public actor Qwen3InferenceEngine: LocalLanguageModel {
    public struct Configuration: Sendable {
        /// Hugging Face 모델 식별자
        public var modelId: String
        /// 설정에서 고른 모델을 알려 주는 함수. 있으면 `modelId`보다 우선한다.
        ///
        /// 로드할 때마다 물어보므로, 설정을 바꾸면 다음 생성부터 새 모델이 쓰인다.
        public var modelProvider: (@Sendable () -> String)?
        /// 이미 내려받은 모델 디렉터리. 지정하면 네트워크를 전혀 쓰지 않는다.
        public var localDirectory: URL?
        /// 모델 캐시 디렉터리 (다운로드 위치)
        public var cacheDirectory: URL?
        public var temperature: Float
        public var topP: Float
        /// MLX GPU 캐시 상한(바이트). 16GB 장비에서 캐시가 메모리를 잠식하지 않게 제한한다(§12).
        public var gpuCacheLimit: Int

        public init(
            modelId: String = LanguageModelCatalog.defaultId,
            modelProvider: (@Sendable () -> String)? = nil,
            localDirectory: URL? = nil,
            cacheDirectory: URL? = nil,
            temperature: Float = 0.3,
            topP: Float = 0.9,
            gpuCacheLimit: Int = 128 * 1024 * 1024
        ) {
            self.modelId = modelId
            self.modelProvider = modelProvider
            self.localDirectory = localDirectory
            self.cacheDirectory = cacheDirectory
            self.temperature = temperature
            self.topP = topP
            self.gpuCacheLimit = gpuCacheLimit
        }

        public static func defaultCacheDirectory() -> URL {
            AppIdentity.dataDirectory().appendingPathComponent("models/mlx", isDirectory: true)
        }
    }

    public private(set) var configuration: Configuration
    private var container: ModelContainer?
    /// 지금 올라와 있는 모델 식별자. 설정에서 다른 모델을 고르면 이 값과 달라진다.
    private var loadedModel: String?
    private let log: (@Sendable (String) -> Void)?

    public init(configuration: Configuration = Configuration(), log: (@Sendable (String) -> Void)? = nil) {
        self.configuration = configuration
        self.log = log
    }

    // MARK: - 수명 관리

    /// 지금 써야 할 모델 식별자. 설정이 있으면 그쪽을 따른다.
    private var selectedModel: String {
        // 직접 지정한 폴더로 돌 때는 설정이 아니라 그 폴더의 모델을 쓴다.
        configuration.localDirectory == nil ? (configuration.modelProvider?() ?? configuration.modelId) : configuration.modelId
    }

    public func load() async throws {
        let modelId = selectedModel
        // 설정에서 모델을 바꿨으면 올라와 있던 것을 내리고 새로 올린다.
        // 로드는 각 단계 진입 때만 부르므로 생성 도중에 바뀌지 않는다.
        if container != nil, loadedModel != modelId {
            log?("회의록 생성 모델 변경: \(loadedModel ?? "없음") → \(modelId)")
            await unload()
        }
        guard container == nil else { return }
        let started = Date()
        MLX.GPU.set(cacheLimit: configuration.gpuCacheLimit)

        do {
            if let directory = configuration.localDirectory {
                container = try await loadModelContainer(
                    from: directory,
                    using: #huggingFaceTokenizerLoader()
                )
            } else {
                let cacheDirectory = configuration.cacheDirectory ?? Configuration.defaultCacheDirectory()
                try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
                let client = HubClient(cache: HubCache(cacheDirectory: cacheDirectory))
                container = try await loadModelContainer(
                    from: #hubDownloader(client),
                    using: #huggingFaceTokenizerLoader(),
                    configuration: ModelConfiguration(id: modelId)
                )
            }
            loadedModel = modelId
        } catch {
            throw InferenceError.modelUnavailable(
                "\(modelId) 로드 실패: \(error.localizedDescription)"
            )
        }

        log?(
            String(
                format: "Qwen3(%@) 로드 %.1fs, MLX active=%.0fMB",
                modelId,
                Date().timeIntervalSince(started),
                Double(MLX.GPU.activeMemory) / 1_048_576
            )
        )
    }

    public func unload() async {
        guard container != nil else { return }
        container = nil
        loadedModel = nil
        MLX.GPU.clearCache()
        log?(String(format: "Qwen3 해제, MLX active=%.0fMB", Double(MLX.GPU.activeMemory) / 1_048_576))
    }

    // MARK: - 생성

    public func generate(prompt: String, mode: ReasoningMode, maxTokens: Int) async throws -> String {
        try await generate(systemPrompt: nil, prompt: prompt, mode: mode, maxTokens: maxTokens)
    }

    public func generate(
        systemPrompt: String?,
        prompt: String,
        mode: ReasoningMode,
        maxTokens: Int
    ) async throws -> String {
        try await load()
        guard let container else {
            throw InferenceError.modelUnavailable("엔진이 로드되지 않음")
        }

        var parameters = GenerateParameters(
            maxTokens: maxTokens,
            temperature: mode == .thinking ? 0.6 : configuration.temperature,
            topP: configuration.topP
        )
        // KV 캐시 상한을 두어 긴 프롬프트에서도 메모리를 예측 가능하게 만든다.
        parameters.maxKVSize = 8192

        // Qwen3 채팅 템플릿의 `enable_thinking` 인자로 사고 모드를 전환한다.
        // 템플릿이 인자를 무시하는 환경에서도 동작하도록, 비사고 모드에서는 `/no_think` 소프트 스위치를 함께 쓴다.
        let session = ChatSession(
            container,
            instructions: systemPrompt,
            generateParameters: parameters,
            additionalContext: ["enable_thinking": mode == .thinking]
        )
        let userPrompt = mode == .thinking ? prompt : prompt + "\n\n/no_think"

        let started = Date()
        let raw = try await session.respond(to: userPrompt)
        log?(
            String(
                format: "생성(%@) %.1fs, 출력 %d자",
                mode.rawValue,
                Date().timeIntervalSince(started),
                raw.count
            )
        )
        // 내부 사고 내용은 호출자에게 넘기지 않는다.
        return ThinkingStripper.strip(raw).visibleText
    }
}
