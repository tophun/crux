import Foundation

/// 회의록 문서 구성 프롬프트 저장소.
///
/// 파이프라인이 액터 안에서 읽으므로 스레드 안전한 `UserDefaults`를 단일 저장소로 쓴다.
public enum DocumentPromptStore {
    private static let key = "note.documentPrompt"

    public static var prompt: String {
        get { UserDefaults.standard.string(forKey: key) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
