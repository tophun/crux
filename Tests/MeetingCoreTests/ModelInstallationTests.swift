import Foundation
import MeetingCore
import Testing

/// 모델 설치 판정과 온보딩 게이트의 모델 항목.
///
/// 실제 다운로드는 네트워크가 필요해 여기서 보지 않고,
/// "디스크에 있으면 설치된 것"이라는 판정 규칙만 고정한다.
struct ModelInstallationTests {
    @Test("Whisper 변형 폴더가 있고 비어 있지 않으면 설치됨")
    func whisperInstalled() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crux-test-\(UUID().uuidString)", isDirectory: true)
        let variant = base.appendingPathComponent("openai_whisper-large-v3-v20240930_turbo", isDirectory: true)
        try FileManager.default.createDirectory(at: variant, withIntermediateDirectories: true)

        #expect(!ModelStoreLayout.isWhisperVariantInstalled(base: base, variant: "openai_whisper-large-v3-v20240930_turbo"))

        try Data("weights".utf8).write(to: variant.appendingPathComponent("model.bin"))
        #expect(ModelStoreLayout.isWhisperVariantInstalled(base: base, variant: "openai_whisper-large-v3-v20240930_turbo"))
    }

    @Test("MLX 스냅숏 리비전이 있으면 설치됨")
    func mlxInstalled() throws {
        let cache = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crux-test-\(UUID().uuidString)", isDirectory: true)
        let repoId = "mlx-community/Qwen3-4B-4bit"
        let snapshot = ModelStoreLayout.mlxSnapshotsDirectory(cacheDirectory: cache, repoId: repoId)
            .appendingPathComponent("abc123def", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)

        #expect(!ModelStoreLayout.isMLXModelInstalled(cacheDirectory: cache, repoId: repoId))

        try Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))
        #expect(ModelStoreLayout.isMLXModelInstalled(cacheDirectory: cache, repoId: repoId))
        #expect(ModelStoreLayout.mlxRepoCacheRoot(cacheDirectory: cache, repoId: repoId)
            .lastPathComponent == "models--mlx-community--Qwen3-4B-4bit")
    }

    @Test("온보딩 게이트는 권한과 모델을 함께 센다")
    func gateCountsModels() {
        // 모두 충족
        #expect(
            OnboardingGate.remainingRequired(
                calendarAuthorized: true,
                microphoneGranted: true,
                transcriptionModelInstalled: true,
                languageModelInstalled: true
            ) == 0
        )
        // 모델 하나만 빠짐
        #expect(
            OnboardingGate.remainingRequired(
                calendarAuthorized: true,
                microphoneGranted: true,
                transcriptionModelInstalled: false,
                languageModelInstalled: true
            ) == 1
        )
        // 기본값은 모델을 세지 않는다 — 기존 부르는 곳의 동작을 유지한다.
        #expect(OnboardingGate.remainingRequired(calendarAuthorized: true, microphoneGranted: true) == 0)
    }
}
