import Foundation
import MeetingCore

/// 회의 감지 기준 설정.
///
/// 기본값은 명세대로 **참석자 2명 이상**이다. 혼자만 있는 일정은 보통 개인 일정이라
/// 캡슐을 띄우면 방해가 된다. 다만 혼자 만든 일정으로 시험해 보거나,
/// 참석자를 초대하지 않고 일정만 잡아 두는 사람도 있어 설정에서 낮출 수 있게 한다.
///
/// 감지 루프가 액터 밖에서 읽으므로 스레드 안전한 `UserDefaults`를 단일 저장소로 쓴다.
public enum MeetingDetectionSettings {
    private static let key = "detection.minimumAttendees"

    /// 명세 기본값. 참석자가 이 수보다 적은 일정은 회의로 보지 않는다.
    public static let standardMinimumAttendees = MeetingDetectionPolicy.Configuration().minimumAttendees

    public static var minimumAttendees: Int {
        get {
            guard let stored = UserDefaults.standard.object(forKey: key) as? Int else {
                return standardMinimumAttendees
            }
            return max(0, stored)
        }
        set { UserDefaults.standard.set(max(0, newValue), forKey: key) }
    }

    /// 참석자가 없는 일정도 회의로 볼지. 설정 화면의 토글에 대응한다.
    public static var includesSoloEvents: Bool {
        get { minimumAttendees == 0 }
        set { minimumAttendees = newValue ? 0 : standardMinimumAttendees }
    }
}
