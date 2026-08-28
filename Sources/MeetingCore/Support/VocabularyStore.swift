import Foundation

/// 설정 화면의 용어 목록. 이 기기의 `UserDefaults`에만 저장한다.
///
/// 전사 엔진이 액터 안에서 읽으므로 스레드 안전한 `UserDefaults`를 단일 저장소로 쓴다.
/// 기본값은 꺼짐이다. `bool(forKey:)`는 값이 없으면 `false`를 돌려준다.
public struct VocabularyStore: @unchecked Sendable {
    private let defaults: UserDefaults

    private static let enabledKey = "transcription.vocabularyEnabled"
    private static let termsKey = "transcription.vocabularyTerms"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 앱·엔진이 읽는 기본 저장소.
    public static let standard = VocabularyStore()

    public var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    public var terms: [String] {
        get { VocabularyHint.normalized(defaults.stringArray(forKey: Self.termsKey) ?? []) }
        nonmutating set { defaults.set(VocabularyHint.normalized(newValue), forKey: Self.termsKey) }
    }

    public var hint: VocabularyHint {
        get { VocabularyHint(isEnabled: isEnabled, terms: terms) }
        nonmutating set {
            isEnabled = newValue.isEnabled
            terms = newValue.terms
        }
    }

    /// 전사 파이프라인에 넘길 값. 꺼져 있으면 용어가 있어도 `nil`.
    public var transcriptionHint: String? {
        hint.transcriptionHint
    }

    @discardableResult
    public func addTerm(_ term: String) -> Bool {
        var next = hint
        let before = next.terms
        next.add(term)
        guard next.terms != before else { return false }
        terms = next.terms
        return true
    }

    public func removeTerm(_ term: String) {
        var next = hint
        next.remove(term)
        terms = next.terms
    }
}
