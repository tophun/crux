import Foundation
import MeetingCore

/// 사용자가 고른 모델 저장소.
///
/// 엔진이 액터 안에서 읽으므로 스레드 안전한 `UserDefaults`를 단일 저장소로 쓴다.
/// 읽을 때마다 목록과 대조해, 앱 갱신으로 사라진 모델이 저장돼 있어도 기본값으로 되돌아간다.
public enum ModelPreferenceStore {
    private static let transcriptionKey = "models.transcription"
    private static let languageKey = "models.language"

    public static var transcriptionModel: String {
        get { TranscriptionModelCatalog.resolve(UserDefaults.standard.string(forKey: transcriptionKey)) }
        set { UserDefaults.standard.set(newValue, forKey: transcriptionKey) }
    }

    public static var languageModel: String {
        get { LanguageModelCatalog.resolve(UserDefaults.standard.string(forKey: languageKey)) }
        set { UserDefaults.standard.set(newValue, forKey: languageKey) }
    }
}
