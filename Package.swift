// swift-tools-version: 6.2
//
// Crux — 온디바이스 AI 회의록 macOS 앱
//
// 제품명은 Crux로 확정되었다. 모듈 이름에는 제품명을 넣지 않고 기능 이름만 사용한다.
// 제품명·번들 이름이 바뀌는 곳:
//   1. Sources/MeetingCore/Support/AppIdentity.swift 의 `productName` / `bundleName`
//   2. scripts/make_app.sh 의 APP_NAME / DISPLAY_NAME / BUNDLE_ID
import PackageDescription

let package = Package(
    name: "meeting-notes",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MeetingCore", targets: ["MeetingCore"]),
        .library(name: "MeetingPersistence", targets: ["MeetingPersistence"]),
        .library(name: "MeetingPipeline", targets: ["MeetingPipeline"]),
        .library(name: "MeetingAudio", targets: ["MeetingAudio"]),
        .library(name: "MeetingTranscription", targets: ["MeetingTranscription"]),
        .library(name: "MeetingInference", targets: ["MeetingInference"]),
        .library(name: "MeetingPublishing", targets: ["MeetingPublishing"]),
        .library(name: "MeetingCalendar", targets: ["MeetingCalendar"]),
        .library(name: "MeetingUI", targets: ["MeetingUI"]),
        .executable(name: "meetingctl", targets: ["MeetingCLI"]),
        .executable(name: "crux", targets: ["MeetingApp"]),
    ],
    dependencies: [
        // 음성 인식 (WhisperKit). 모델 파일 최초 다운로드에만 네트워크를 사용한다.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0"),
        // 로컬 LLM 실행 (MLX Swift). MLXLLM/MLXLMCommon/MLXHuggingFace 제공.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", .upToNextMinor(from: "3.31.4")),
        // 토크나이저 + 채팅 템플릿(Jinja). Qwen3 `enable_thinking` 템플릿 인자에 필요.
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.3"),
        // HuggingFace Hub 클라이언트 (모델 스냅샷 다운로드 전용)
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.8.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        // MARK: - 도메인 + 추론 정책 (외부 의존성 없음 → 테스트가 모델 없이 전부 돌아간다)
        .target(name: "MeetingCore"),

        // MARK: - 저장소
        .target(
            name: "MeetingPersistence",
            dependencies: ["MeetingCore", "CSQLite"]
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
        .target(
            name: "MeetingInference",
            dependencies: [
                "MeetingCore",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // MARK: - 외부 게시 (캘린더 API와 분리된 Atlassian HTTP 모듈)
        .target(name: "MeetingPublishing", dependencies: ["MeetingCore"]),

        // MARK: - 캘린더 (EventKit + Google Calendar API)
        .target(
            name: "MeetingCalendar",
            dependencies: ["MeetingCore"],
            linkerSettings: [
                .linkedFramework("EventKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
            ]
        ),

        // MARK: - 오케스트레이션
        .target(
            name: "MeetingPipeline",
            dependencies: ["MeetingCore", "MeetingPersistence", "MeetingAudio", "MeetingPublishing"]
        ),

        // MARK: - UI
        .target(
            name: "MeetingUI",
            dependencies: [
                "MeetingCore", "MeetingPipeline", "MeetingPersistence",
                "MeetingPublishing", "MeetingCalendar", "MeetingAudio",
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("UserNotifications")]
        ),

        // MARK: - 실행 타깃
        .executableTarget(
            name: "MeetingApp",
            dependencies: [
                "MeetingCore", "MeetingUI", "MeetingPipeline", "MeetingPersistence",
                "MeetingTranscription", "MeetingInference", "MeetingPublishing", "MeetingCalendar",
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "MeetingCLI",
            dependencies: [
                "MeetingCore", "MeetingPipeline", "MeetingPersistence",
                "MeetingTranscription", "MeetingInference", "MeetingPublishing", "MeetingCalendar",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // MARK: - 테스트 (무거운 모델 없이 동작)
        .testTarget(name: "MeetingCoreTests", dependencies: ["MeetingCore"]),
        .testTarget(
            name: "MeetingPipelineTests",
            dependencies: ["MeetingCore", "MeetingPipeline", "MeetingPersistence"]
        ),
        .testTarget(
            name: "MeetingPersistenceTests",
            dependencies: ["MeetingCore", "MeetingPersistence", "CSQLite"]
        ),
        .testTarget(
            name: "MeetingPublishingTests",
            dependencies: ["MeetingCore", "MeetingPublishing"]
        ),
        .testTarget(
            name: "MeetingCalendarTests",
            dependencies: ["MeetingCore", "MeetingCalendar"]
        ),
    ]
)
