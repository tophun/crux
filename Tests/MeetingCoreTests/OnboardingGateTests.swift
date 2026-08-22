@testable import MeetingCore
import Testing

@Suite("첫 실행 안내")
struct OnboardingGateTests {
    @Test("필수 권한이 모두 있으면 안내를 띄우지 않는다")
    func hiddenWhenReady() {
        #expect(!OnboardingGate.shouldPresent(calendarAuthorized: true, microphoneGranted: true))
        #expect(OnboardingGate.remainingRequired(calendarAuthorized: true, microphoneGranted: true) == 0)
    }

    @Test("하나라도 없으면 띄운다")
    func shownWhenMissing() {
        #expect(OnboardingGate.shouldPresent(calendarAuthorized: false, microphoneGranted: true))
        #expect(OnboardingGate.shouldPresent(calendarAuthorized: true, microphoneGranted: false))
        #expect(OnboardingGate.remainingRequired(calendarAuthorized: false, microphoneGranted: false) == 2)
    }

    @Test("시스템 오디오는 필수가 아니라 판단에 들어가지 않는다")
    func systemAudioIsOptional() {
        // 시스템 오디오 상태와 무관하게 캘린더·마이크만 본다.
        #expect(!OnboardingGate.shouldPresent(calendarAuthorized: true, microphoneGranted: true))
    }

    @Test("권한이 모두 있어도 기본 모델이 없으면 띄운다")
    func shownWhenModelMissing() {
        #expect(
            OnboardingGate.shouldPresent(
                calendarAuthorized: true,
                microphoneGranted: true,
                transcriptionModelInstalled: false,
                languageModelInstalled: true
            )
        )
        #expect(
            OnboardingGate.shouldPresent(
                calendarAuthorized: true,
                microphoneGranted: true,
                transcriptionModelInstalled: true,
                languageModelInstalled: false
            )
        )
        #expect(
            !OnboardingGate.shouldPresent(
                calendarAuthorized: true,
                microphoneGranted: true,
                transcriptionModelInstalled: true,
                languageModelInstalled: true
            )
        )
    }
}
