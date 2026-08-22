// swift-tools-version: 6.2
//
// [PROJECT_NAME] — 온디바이스 AI 회의록 macOS 앱
//
// 제품명은 아직 확정되지 않았으므로 모듈 이름에는 제품명을 넣지 않고 기능 이름만 사용한다.
// 제품명을 확정하면 다음 두 곳만 바꾸면 된다.
//   1. Sources/MeetingCore/Support/AppIdentity.swift 의 `productName`
//   2. Scripts/make_app.sh 의 번들 식별자 (Phase 2)
import PackageDescription

let package = Package(
    name: "meeting-notes",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MeetingCore", targets: ["MeetingCore"]),
        .library(name: "MeetingPersistence", targets: ["MeetingPersistence"]),
        .library(name: "MeetingAudio", targets: ["MeetingAudio"]),
        .library(name: "MeetingTranscription", targets: ["MeetingTranscription"]),
    ],
    dependencies: [
        // 음성 인식 (WhisperKit). 모델 파일 최초 다운로드에만 네트워크를 사용한다.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0"),
        // SQLite
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.0"),
    ],
    targets: [
        // MARK: - 도메인 + 추론 정책 (외부 의존성 없음 → 테스트가 모델 없이 전부 돌아간다)
        .target(name: "MeetingCore"),

        // MARK: - 저장소
        .target(
            name: "MeetingPersistence",
            dependencies: ["MeetingCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),

        // MARK: - 오디오 (Phase 1: 파일 검사/분할, Phase 2: 캡처)
        .target(
            name: "MeetingAudio",
            dependencies: ["MeetingCore"],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        ),

        // MARK: - 무거운 엔진 (프로토콜 뒤에 격리)
        .target(
            name: "MeetingTranscription",
            dependencies: [
                "MeetingCore",
                "MeetingAudio",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // MARK: - 테스트 (무거운 모델 없이 동작)
        .testTarget(name: "MeetingCoreTests", dependencies: ["MeetingCore"]),
        .testTarget(
            name: "MeetingPersistenceTests",
            dependencies: ["MeetingCore", "MeetingPersistence"]
        ),
    ]
)
