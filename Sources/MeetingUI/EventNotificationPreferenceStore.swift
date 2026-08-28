import Foundation
import MeetingCore

/// 일정 로컬 알림의 기본 오프셋.
///
/// 상세 화면이 액터 밖에서 읽으므로 스레드 안전한 `UserDefaults`를 단일 저장소로 쓴다.
public enum EventNotificationPreferenceStore {
    private static let key = "notification.leadMinutes"

    public static var leadMinutes: Int {
        get {
            guard let stored = UserDefaults.standard.object(forKey: key) as? Int else {
                return EventNotificationSettings.defaultLeadMinutes
            }
            return EventNotificationSettings.clamped(stored)
        }
        set { UserDefaults.standard.set(EventNotificationSettings.clamped(newValue), forKey: key) }
    }

    public static var settings: EventNotificationSettings {
        EventNotificationSettings(leadMinutes: leadMinutes)
    }
}
