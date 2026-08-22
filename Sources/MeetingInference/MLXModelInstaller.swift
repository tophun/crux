import Foundation
import HuggingFace
import MeetingCore

/// MLX(HuggingFace 리포지터리) 모델 하나를 내려받는 설치기.
///
/// `Qwen3InferenceEngine`이 로드 때 쓰는 것과 같은 `HubCache` 위치에 받으므로,
/// 여기서 설치한 모델은 엔진이 네트워크 없이 바로 로드한다.
public struct MLXModelInstaller: ModelInstalling {
    /// 리포지터리 식별자. 예: `mlx-community/Qwen3-4B-4bit`
    public let modelId: String
    private let cacheDirectory: URL

    public init(
        modelId: String,
        cacheDirectory: URL = Qwen3InferenceEngine.Configuration.defaultCacheDirectory()
    ) {
        self.modelId = modelId
        self.cacheDirectory = cacheDirectory
    }

    public func isInstalled() -> Bool {
        ModelStoreLayout.isMLXModelInstalled(cacheDirectory: cacheDirectory, repoId: modelId)
    }

    public func install(progress: (@MainActor @Sendable (Double) -> Void)?) async throws {
        guard !isInstalled() else { return }
        // "namespace/name" 형태의 식별자를 HubClient가 기대하는 Repo.ID로 쪼갠다.
        let parts = modelId.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw ModelInstallError.downloadFailed("모델 식별자 형식이 올바르지 않습니다: \(modelId)")
        }
        var handler: (@MainActor @Sendable (Progress) -> Void)?
        if let progress {
            handler = { @MainActor snapshot in
                progress(snapshot.fractionCompleted)
            }
        }
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            // 엔진 로드 경로와 같은 클라이언트·캐시 구성을 쓴다.
            let client = HubClient(cache: HubCache(cacheDirectory: cacheDirectory))
            _ = try await client.downloadSnapshot(
                of: Repo.ID(namespace: parts[0], name: parts[1]),
                kind: .model,
                progressHandler: handler
            )
        } catch {
            throw ModelInstallError.downloadFailed(error.localizedDescription)
        }
    }
}
