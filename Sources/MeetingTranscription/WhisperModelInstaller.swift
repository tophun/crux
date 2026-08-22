import Foundation
import MeetingCore
import WhisperKit

/// WhisperKit 모델 한 변형을 내려받는 설치기.
///
/// 저장 위치 규칙(`ModelStoreLayout`)과 실제 WhisperKit의 다운로드·로드 규칙이 같으므로,
/// 여기서 설치된 모델은 엔진이 네트워크 없이 바로 로드한다.
public struct WhisperModelInstaller: ModelInstalling {
    /// 카탈로그 변형 식별자. 예: `openai_whisper-large-v3-v20240930_turbo`
    public let modelVariant: String
    private let downloadBase: URL

    public init(
        modelVariant: String,
        downloadBase: URL = WhisperKitTranscriptionEngine.Configuration.defaultDownloadBase()
    ) {
        self.modelVariant = modelVariant
        self.downloadBase = downloadBase
    }

    public func isInstalled() -> Bool {
        ModelStoreLayout.isWhisperVariantInstalled(base: downloadBase, variant: modelVariant)
    }

    public func install(progress: (@MainActor @Sendable (Double) -> Void)?) async throws {
        guard !isInstalled() else { return }
        do {
            // WhisperKit의 콜백은 백그라운드에서 오므로 메인 액터로 옮겨 준다.
            _ = try await WhisperKit.download(
                variant: modelVariant,
                downloadBase: downloadBase,
                progressCallback: progress.map { callback in { progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in callback(fraction) }
                } }
            )
        } catch {
            throw ModelInstallError.downloadFailed(error.localizedDescription)
        }
    }
}
