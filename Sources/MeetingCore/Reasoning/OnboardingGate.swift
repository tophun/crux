import Foundation

/// 첫 실행 안내를 언제 띄울지.
///
/// 필수 권한(캘린더·마이크)이나 기본 모델(음성 인식·회의록 생성)이 하나라도 없으면
/// 앱을 켤 때 띄운다. 시스템 오디오는 없어도 마이크만으로 녹음할 수 있으므로
/// 필수로 보지 않는다. 권한 타입이 모듈마다 달라 참·거짓만 받는다.
public enum OnboardingGate {
    /// 모델 설치 여부는 기본값이 true라, 모델을 세지 않는 기존 부르는 곳은 그대로 동작한다.
    public static func shouldPresent(
        calendarAuthorized: Bool,
        microphoneGranted: Bool,
        transcriptionModelInstalled: Bool = true,
        languageModelInstalled: Bool = true
    ) -> Bool {
        !calendarAuthorized || !microphoneGranted
            || !transcriptionModelInstalled || !languageModelInstalled
    }

    /// 아직 받지 못한 필수 권한 수. 안내 화면 아래에 보여 준다.
    ///
    /// 모델도 녹음·회의록 생성의 전제 조건이므로 함께 센다. 기본값은 true라,
    /// 모델을 세지 않는 기존 부르는 곳은 그대로 동작한다.
    public static func remainingRequired(
        calendarAuthorized: Bool,
        microphoneGranted: Bool,
        transcriptionModelInstalled: Bool = true,
        languageModelInstalled: Bool = true
    ) -> Int {
        (calendarAuthorized ? 0 : 1)
            + (microphoneGranted ? 0 : 1)
            + (transcriptionModelInstalled ? 0 : 1)
            + (languageModelInstalled ? 0 : 1)
    }

    /// 안내를 닫고 앱을 쓸 수 있는지. 필수 권한이나 기본 모델이 남아 있으면
    /// "나중에 하기"로 건너뛰지 않는다. 시스템 오디오는 선택이라 보지 않는다.
    public static func canDefer(
        calendarAuthorized: Bool,
        microphoneGranted: Bool,
        transcriptionModelInstalled: Bool = true,
        languageModelInstalled: Bool = true
    ) -> Bool {
        remainingRequired(
            calendarAuthorized: calendarAuthorized,
            microphoneGranted: microphoneGranted,
            transcriptionModelInstalled: transcriptionModelInstalled,
            languageModelInstalled: languageModelInstalled
        ) == 0
    }

    /// 녹음·가져오기를 시작할 수 있는지. 캘린더는 감지용이므로 수동 시작에는
    /// 필요 없고, 마이크와 두 기본 모델이 있어야 처리가 실패하지 않는다.
    public static func canStartRecording(
        microphoneGranted: Bool,
        transcriptionModelInstalled: Bool,
        languageModelInstalled: Bool
    ) -> Bool {
        microphoneGranted && transcriptionModelInstalled && languageModelInstalled
    }
}
