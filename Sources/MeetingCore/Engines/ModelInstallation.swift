import Foundation

/// 모델 하나의 설치·내려받기 담당. 구현은 각 엔진 모듈(WhisperKit·MLX)이 제공하고,
/// UI는 이 프로토콜만 안다. 네트워크를 쓰는 곳은 `install`뿐이다.
public protocol ModelInstalling: Sendable {
    /// 모델 파일이 디스크에 있는지. 네트워크를 쓰지 않으므로 자주 물어도 부담이 없다.
    func isInstalled() -> Bool

    /// 모델을 내려받는다. 이미 설치돼 있으면 아무 것도 하지 않고 돌아온다.
    /// - Parameter progress: 0...1 진행률. 메인 액터에서 불린다.
    func install(progress: (@MainActor @Sendable (Double) -> Void)?) async throws
}

public enum ModelInstallError: Error, LocalizedError, Sendable {
    case downloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .downloadFailed(message):
            "모델 내려받기에 실패했습니다: \(message)"
        }
    }
}

/// 모델 저장 위치 규칙.
///
/// 엔진이 실제로 읽는 경로와 같은 규칙이므로, 여기서 "설치됨"이라고 판정하면
/// 엔진도 네트워크 없이 그 모델을 로드할 수 있다.
public enum ModelStoreLayout {
    /// WhisperKit은 `<base>/<변형 이름>/…` 폴더 구조로 저장한다.
    public static func whisperVariantDirectory(base: URL, variant: String) -> URL {
        base.appendingPathComponent(variant, isDirectory: true)
    }

    /// 변형 폴더가 존재하고 그 안에 파일이 하나 이상 있으면 설치된 것으로 본다.
    public static func isWhisperVariantInstalled(base: URL, variant: String) -> Bool {
        directoryContainsFiles(whisperVariantDirectory(base: base, variant: variant))
    }

    /// MLX(HubCache)는 `<cache>/models--<org>--<name>/snapshots/<리비전>/…` 구조다.
    public static func mlxRepoCacheRoot(cacheDirectory: URL, repoId: String) -> URL {
        let repoName = repoId.replacingOccurrences(of: "/", with: "--")
        return cacheDirectory.appendingPathComponent("models--\(repoName)", isDirectory: true)
    }

    public static func mlxSnapshotsDirectory(cacheDirectory: URL, repoId: String) -> URL {
        mlxRepoCacheRoot(cacheDirectory: cacheDirectory, repoId: repoId)
            .appendingPathComponent("snapshots", isDirectory: true)
    }

    /// 리비전 스냅숏 폴더가 하나라도 있고 그 안에 파일이 있으면 설치된 것으로 본다.
    public static func isMLXModelInstalled(cacheDirectory: URL, repoId: String) -> Bool {
        let snapshots = mlxSnapshotsDirectory(cacheDirectory: cacheDirectory, repoId: repoId)
        guard let revisions = try? FileManager.default.contentsOfDirectory(
            at: snapshots, includingPropertiesForKeys: nil
        ) else { return false }
        return revisions.contains { directoryContainsFiles($0) }
    }

    /// 폴더 안에 파일이 하나라도 있는지. 하위 폴더까지는 보지 않는다 — 모델 루트에는
    /// 항상 설정 파일이나 가중치 파일이 바로 놓인다.
    static func directoryContainsFiles(_ directory: URL) -> Bool {
        let contents = (try? FileManager.default.contentsOfDirectory(
            atPath: directory.path
        )) ?? []
        return !contents.isEmpty
    }
}
