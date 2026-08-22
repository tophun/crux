import Foundation
import MeetingCore

/// 모델 설치 상태를 관찰하고 내려받기를 실행하는 중심.
///
/// 설정·온보딩·메뉴바가 같은 인스턴스를 바라보므로 상태가 한 곳에서만 갱신된다.
/// 판정은 파일 존재만 보는 저렴한 확인이고, 실제 내려받기는 엔진별
/// `ModelInstalling` 구현(WhisperKit·MLX)이 맡는다.
@MainActor
@Observable
public final class ModelInstallCenter {
    public enum Status: Equatable {
        case installed
        case notInstalled
        case installing(fraction: Double)

        public var isInstalled: Bool {
            self == .installed
        }
    }

    public private(set) var transcription: [String: Status] = [:]
    public private(set) var language: [String: Status] = [:]
    /// 마지막 설치 실패 메시지. 화면에 그대로 보여 준다. 성공하면 지운다.
    public private(set) var lastErrorMessage: String?

    private let transcriptionInstallers: [String: any ModelInstalling]
    private let languageInstallers: [String: any ModelInstalling]
    private var installingTranscriptionId: String?
    private var installingLanguageId: String?

    public init(
        transcriptionInstallers: [String: any ModelInstalling],
        languageInstallers: [String: any ModelInstalling]
    ) {
        self.transcriptionInstallers = transcriptionInstallers
        self.languageInstallers = languageInstallers
        refresh()
    }

    /// 디스크 존재만 보는 판정이라 자주 불러도 부담이 없다.
    /// 내려받기 진행 중인 항목은 덮어쓰지 않는다.
    public func refresh() {
        if installingTranscriptionId == nil {
            for (id, installer) in transcriptionInstallers {
                transcription[id] = installer.isInstalled() ? .installed : .notInstalled
            }
        }
        if installingLanguageId == nil {
            for (id, installer) in languageInstallers {
                language[id] = installer.isInstalled() ? .installed : .notInstalled
            }
        }
    }

    /// 녹음을 시작할 수 있는지. 선택된 음성 인식·회의록 생성 모델이 둘 다 있어야 한다.
    /// 하나라도 없으면 처리가 도중에 실패하므로, 시작 자체를 막고 먼저 받게 안내한다.
    public var readyForCapture: Bool {
        status(transcription[ModelPreferenceStore.transcriptionModel]).isInstalled
            && status(language[ModelPreferenceStore.languageModel]).isInstalled
    }

    /// 온보딩·설정 화면이 선택 모델의 상태를 바로 읽을 때 쓴다.
    public func selectedTranscriptionStatus() -> Status {
        status(transcription[ModelPreferenceStore.transcriptionModel])
    }

    public func selectedLanguageStatus() -> Status {
        status(language[ModelPreferenceStore.languageModel])
    }

    public func installTranscription(_ id: String) {
        run(installer: transcriptionInstallers[id], id: id, isTranscription: true)
    }

    public func installLanguage(_ id: String) {
        run(installer: languageInstallers[id], id: id, isTranscription: false)
    }

    // MARK: - 내부

    private func status(_ value: Status?) -> Status {
        value ?? .notInstalled
    }

    /// 같은 역할의 설치가 겹치지 않게 하나씩만 돌린다.
    private func run(
        installer: (any ModelInstalling)?,
        id: String,
        isTranscription: Bool
    ) {
        guard let installer else { return }
        if isTranscription {
            guard installingTranscriptionId == nil else { return }
            installingTranscriptionId = id
        } else {
            guard installingLanguageId == nil else { return }
            installingLanguageId = id
        }
        set(status: .installing(fraction: 0), for: id, isTranscription: isTranscription)
        lastErrorMessage = nil

        Task { [weak self] in
            await self?.perform(installer: installer, id: id, isTranscription: isTranscription)
        }
    }

    private func perform(
        installer: any ModelInstalling,
        id: String,
        isTranscription: Bool
    ) async {
        do {
            try await installer.install(progress: { [weak self] fraction in
                self?.set(status: .installing(fraction: fraction), for: id, isTranscription: isTranscription)
            })
            set(status: .installed, for: id, isTranscription: isTranscription)
        } catch {
            lastErrorMessage = error.localizedDescription
            set(status: .notInstalled, for: id, isTranscription: isTranscription)
        }
        if isTranscription {
            installingTranscriptionId = nil
        } else {
            installingLanguageId = nil
        }
        refresh()
    }

    private func set(status: Status, for id: String, isTranscription: Bool) {
        if isTranscription {
            transcription[id] = status
        } else {
            language[id] = status
        }
    }
}
