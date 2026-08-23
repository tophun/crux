import ArgumentParser
import Foundation
import MeetingCore
import MeetingInference
import MeetingTranscription

/// 온보딩과 같은 설치기로 기본 모델 상태를 확인하고 내려받는다.
struct ModelsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models",
        abstract: "기본 음성 인식·회의록 생성 모델 설치 상태를 확인하고 내려받는다"
    )

    @Flag(name: .long, help: "없는 모델을 내려받는다")
    var install = false

    func run() async throws {
        let whisper = WhisperModelInstaller(modelVariant: TranscriptionModelCatalog.defaultId)
        let language = MLXModelInstaller(modelId: LanguageModelCatalog.defaultId)

        printStatus(role: "음성 인식", id: TranscriptionModelCatalog.defaultId, installed: whisper.isInstalled())
        printStatus(role: "회의록 생성", id: LanguageModelCatalog.defaultId, installed: language.isInstalled())

        guard install else { return }

        try await installIfNeeded(role: "음성 인식", installer: whisper)
        try await installIfNeeded(role: "회의록 생성", installer: language)

        guard whisper.isInstalled(), language.isInstalled() else {
            throw ExitCode.failure
        }
    }

    private func printStatus(role: String, id: String, installed: Bool) {
        print("\(role) \(id): \(installed ? "설치됨" : "없음")")
    }

    private func installIfNeeded(role: String, installer: any ModelInstalling) async throws {
        if installer.isInstalled() {
            print("\(role): 이미 설치됨")
            return
        }
        print("\(role) 모델 내려받기…")
        do {
            try await installer.install { fraction in
                let line = String(format: "\r\(role) %.1f%%", fraction * 100)
                FileHandle.standardError.write(Data(line.utf8))
            }
            FileHandle.standardError.write(Data("\n".utf8))
            print("\(role): \(installer.isInstalled() ? "설치됨" : "내려받은 뒤에도 설치로 보이지 않음")")
        } catch {
            FileHandle.standardError.write(Data("\n".utf8))
            throw error
        }
    }
}
