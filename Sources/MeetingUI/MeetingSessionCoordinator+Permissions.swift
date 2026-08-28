import Foundation
import MeetingAudio
import MeetingCalendar
import MeetingCore

/// 캘린더·마이크·시스템 오디오 권한 조회와 요청.
public extension MeetingSessionCoordinator {
    /// 감지 루프에서 주기적으로 부르는 가벼운 확인. 권한 창을 띄우는 API는 호출하지 않는다.
    func refreshPermissions() async {
        calendarStatus = calendarProvider.authorizationStatus()
        if let preferred = calendarProvider as? PreferredCalendarProvider {
            eventKitStatus = preferred.eventKitStatus()
            googleCalendarStatus = preferred.googleStatus()
        } else {
            eventKitStatus = calendarStatus
            googleCalendarStatus = calendarStatus
        }
        microphoneStatus = await capture.microphonePermission()
    }

    /// 시스템 오디오(화면 기록) 권한 확인. ScreenCaptureKit은 조회 API가 없어 실제 조회로 확인해야 하고,
    /// 그 호출이 권한 창을 띄울 수 있다. 그래서 주기적으로 부르지 않고 사용자 동작에서만 확인한다.
    func refreshSystemAudioPermission() async {
        systemAudioStatus = await capture.systemAudioPermission()
    }

    /// 설정·온보딩의 '허용' 버튼용. 아직 정해지지 않았으면 시스템 대화상자를 띄운다.
    func requestSystemAudioPermission() async {
        systemAudioStatus = await capture.requestSystemAudioPermission()
    }

    func requestRecordingPermissions() async {
        let result = await capture.requestPermissions()
        microphoneStatus = result.microphone
        systemAudioStatus = result.systemAudio
    }
}
