import Foundation

/// 파일 로그. 앱을 Finder에서 실행하면 표준 출력이 사라져 문제를 추적할 수 없다.
///
/// `~/Library/Logs/LiveCapsule/live-capsule.log`에 남긴다. 회의 내용·오디오·토큰은 남기지 않는다.
public struct AppLog: Sendable {
    public enum Category: String, Sendable {
        case session, audio, pipeline, model, publish, ui
    }

    public static let shared = AppLog()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "app-log")
    private let alsoPrint: Bool

    public init(fileURL: URL? = nil, alsoPrint: Bool = true) {
        self.fileURL = fileURL ?? Self.defaultURL
        self.alsoPrint = alsoPrint
    }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return base
            .appendingPathComponent("Logs/\(AppIdentity.bundleName)", isDirectory: true)
            .appendingPathComponent("live-capsule.log")
    }

    public func write(_ category: Category, _ message: String) {
        let line = "\(Self.timestamp()) [\(category.rawValue)] \(message)\n"
        if alsoPrint { print(line, terminator: "") }
        let url = fileURL
        queue.async {
            let manager = FileManager.default
            try? manager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // 로그가 무한히 커지지 않도록 2MB를 넘으면 새로 시작한다.
            if let size = try? manager.attributesOfItem(atPath: url.path)[.size] as? Int, size > 2_000_000 {
                try? manager.removeItem(at: url)
            }
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// 기존 로그 싱크 자리에 그대로 끼울 수 있는 클로저
    public func sink(_ category: Category) -> @Sendable (String) -> Void {
        { message in self.write(category, message) }
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}
