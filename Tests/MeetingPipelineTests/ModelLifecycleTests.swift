import Foundation
import Testing
@testable import MeetingCore
@testable import MeetingPipeline

@Suite("모델 수명 관리 (16GB 제약)")
struct ModelLifecycleTests {
    @Test("음성 인식 모델과 LLM은 동시에 메모리에 올라가지 않는다")
    func neverBothResident() async throws {
        let monitor = ModelResidencyMonitor()
        let coordinator = ModelLifecycleCoordinator(
            transcriptionEngine: FakeTranscriptionEngine(monitor: monitor) { TestScripts.segments(meetingId: $0) },
            languageModel: ScriptedLanguageModel(monitor: monitor, responder: TestScripts.responder)
        )

        _ = try await coordinator.withTranscription { engine in
            try await engine.transcribe(audioURL: URL(fileURLWithPath: "/dev/null"), meetingId: UUID())
        }
        #expect(await coordinator.residentModel == .transcription)

        _ = try await coordinator.withLanguageModel { model in
            try await model.generate(prompt: "test", mode: .nonThinking, maxTokens: 16)
        }
        #expect(await coordinator.residentModel == .languageModel)

        await coordinator.releaseAll()
        #expect(await coordinator.residentModel == .none)

        let snapshot = await monitor.snapshot()
        #expect(!snapshot.violated, "두 모델이 동시에 상주했다: \(snapshot.events)")
        // 전사 모델 해제가 LLM 로드보다 먼저 일어난다.
        let unloadIndex = snapshot.events.firstIndex(of: "transcription.unload")
        let loadIndex = snapshot.events.firstIndex(of: "language.load")
        #expect(unloadIndex != nil && loadIndex != nil)
        #expect(unloadIndex! < loadIndex!)
    }

    @Test("같은 모델을 반복 사용하면 다시 로드하지 않는다")
    func reusesResidentModel() async throws {
        let monitor = ModelResidencyMonitor()
        let coordinator = ModelLifecycleCoordinator(
            transcriptionEngine: FakeTranscriptionEngine(monitor: monitor) { TestScripts.segments(meetingId: $0) },
            languageModel: ScriptedLanguageModel(monitor: monitor, responder: TestScripts.responder)
        )
        for _ in 0..<3 {
            _ = try await coordinator.withLanguageModel { model in
                try await model.generate(prompt: "test", mode: .nonThinking, maxTokens: 8)
            }
        }
        let snapshot = await monitor.snapshot()
        #expect(snapshot.events.filter { $0 == "language.load" }.count == 1)
    }
}
