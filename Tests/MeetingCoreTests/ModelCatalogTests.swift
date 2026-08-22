import Foundation
import Testing

@testable import MeetingCore

@Suite("모델 목록")
struct ModelCatalogTests {
    @Test("기본 모델은 목록에 들어 있다 — 설정을 열자마자 고른 값이 비지 않는다")
    func defaultsAreListed() {
        #expect(TranscriptionModelCatalog.choice(for: TranscriptionModelCatalog.defaultId) != nil)
        #expect(LanguageModelCatalog.choice(for: LanguageModelCatalog.defaultId) != nil)
    }

    @Test("저장된 값이 목록에 없으면 기본값으로 돌아간다 — 앱 갱신으로 모델이 빠져도 안전하다")
    func unknownFallsBackToDefault() {
        #expect(TranscriptionModelCatalog.resolve("존재하지-않는-모델") == TranscriptionModelCatalog.defaultId)
        #expect(TranscriptionModelCatalog.resolve(nil) == TranscriptionModelCatalog.defaultId)
        #expect(LanguageModelCatalog.resolve("mlx-community/없는모델") == LanguageModelCatalog.defaultId)
        #expect(LanguageModelCatalog.resolve(nil) == LanguageModelCatalog.defaultId)
    }

    @Test("목록에 있는 값은 그대로 쓴다")
    func knownIsKept() {
        let accurate = "openai_whisper-large-v3_turbo"
        #expect(TranscriptionModelCatalog.resolve(accurate) == accurate)
        let large = "mlx-community/Qwen3-14B-4bit"
        #expect(LanguageModelCatalog.resolve(large) == large)
    }

    @Test("회의록 모델은 사고 모드를 지원하는 원본 Qwen3 계열만 담는다")
    func languageModelsAreThinkingCapable() {
        for choice in LanguageModelCatalog.all {
            #expect(choice.id.hasPrefix("mlx-community/Qwen3-"))
            // Instruct-2507 같은 파생 계열은 enable_thinking 전환을 지원하지 않는다.
            #expect(!choice.id.contains("Instruct"))
        }
    }

    @Test("메모리가 모자라면 고를 수 없다 — 처리 도중 메모리가 터지는 것을 막는다")
    func memoryGates() {
        let accurate = TranscriptionModelCatalog.choice(for: "openai_whisper-large-v3_turbo")
        #expect(accurate?.fits(memoryGB: 8) == false)
        #expect(accurate?.fits(memoryGB: 16) == true)

        let small = LanguageModelCatalog.choice(for: "mlx-community/Qwen3-4B-4bit")
        #expect(small?.fits(memoryGB: 8) == true)
    }

    @Test("모든 모델은 16GB 기기에서 쓸 수 있다 — 아무도 고를 수 없는 항목을 두지 않는다")
    func everyChoiceIsReachable() {
        for choice in TranscriptionModelCatalog.all + LanguageModelCatalog.all {
            #expect(choice.fits(memoryGB: 16))
        }
    }

    @Test("기본 모델은 16GB 기기에서 쓸 수 있다 — 설계 기준을 지킨다")
    func defaultsFitBaselineMachine() {
        #expect(TranscriptionModelCatalog.choice(for: TranscriptionModelCatalog.defaultId)?.fits(memoryGB: 16) == true)
        #expect(LanguageModelCatalog.choice(for: LanguageModelCatalog.defaultId)?.fits(memoryGB: 16) == true)
    }
}
