import Foundation

/// 첫 실행 안내를 언제 띄울지.
///
/// 필수 권한(캘린더·마이크)이 하나라도 없으면 앱을 켤 때 띄운다.
/// 시스템 오디오는 없어도 마이크만으로 녹음할 수 있으므로 필수로 보지 않는다.
/// 권한 타입이 모듈마다 달라 참·거짓만 받는다.
public enum OnboardingGate {
    public static func shouldPresent(calendarAuthorized: Bool, microphoneGranted: Bool) -> Bool {
        !calendarAuthorized || !microphoneGranted
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
}
