import Foundation

/// 사용자에게 보이는 제품 이름은 이 한 곳에서만 정의한다.
public enum AppIdentity {
    public static let productName = "Crux"

    /// 파일 시스템·번들에서 쓰는 공백 없는 이름
    public static let bundleName = "Crux"

    /// 로컬 데이터 루트. 외부로 전송되지 않으며 이 디렉터리 밖으로 회의 데이터를 쓰지 않는다.
    public static func dataDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(bundleName, isDirectory: true)
    }
}
