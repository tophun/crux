import Foundation
@testable import MeetingCore
import Testing

@Suite("인식 힌트")
struct VocabularyHintTests {
    @Test("기본값은 꺼짐이다 — 용어를 넣어도 힌트를 넘기지 않는다")
    func defaultIsOffAndPassesNothing() {
        let hint = VocabularyHint(terms: ["똑닥", "홍길동", "TICKET-12"])
        #expect(!hint.isEnabled)
        #expect(hint.transcriptionHint == nil)
    }

    @Test("켜면 용어를 쉼표로 이어 전사 엔진에 넘긴다")
    func enabledPassesJoinedTerms() {
        let hint = VocabularyHint(isEnabled: true, terms: ["똑닥", "홍길동", "TICKET-12"])
        #expect(hint.transcriptionHint == "똑닥, 홍길동, TICKET-12")
    }

    @Test("켜져 있어도 쓸 용어가 없으면 지금과 같이 nil이다")
    func enabledButEmptyPassesNothing() {
        #expect(VocabularyHint(isEnabled: true).transcriptionHint == nil)
        #expect(VocabularyHint(isEnabled: true, terms: ["  ", ""]).transcriptionHint == nil)
    }

    @Test("끄면 같은 용어도 넘기지 않는다")
    func disabledWithTermsMatchesCurrentBehavior() {
        let on = VocabularyHint(isEnabled: true, terms: ["똑닥"])
        let off = VocabularyHint(isEnabled: false, terms: ["똑닥"])
        #expect(on.transcriptionHint == "똑닥")
        #expect(off.transcriptionHint == nil)
    }

    @Test("앞뒤 공백과 빈 항목·중복을 버리고 처음 순서를 지킨다")
    func normalizesTerms() {
        let hint = VocabularyHint(isEnabled: true, terms: [" 똑닥 ", "", "홍길동", "똑닥", "  TICKET-12"])
        #expect(hint.terms == ["똑닥", "홍길동", "TICKET-12"])
        #expect(hint.transcriptionHint == "똑닥, 홍길동, TICKET-12")
    }

    @Test("설정 provider가 있으면 꺼졌을 때 CLI 값으로 넘어가지 않는다")
    func settingsProviderDoesNotFallBackToCLI() {
        let off = VocabularyHint(isEnabled: false, terms: ["똑닥"])
        #expect(VocabularyHint.resolve(provider: { off.transcriptionHint }, cliHint: "QA") == nil)

        let on = VocabularyHint(isEnabled: true, terms: ["똑닥"])
        #expect(VocabularyHint.resolve(provider: { on.transcriptionHint }, cliHint: "QA") == "똑닥")
    }

    @Test("설정 provider가 없으면 CLI 힌트를 그대로 쓴다")
    func cliHintUsedWithoutSettingsProvider() {
        #expect(VocabularyHint.resolve(provider: nil, cliHint: "QA, 릴리즈") == "QA, 릴리즈")
        #expect(VocabularyHint.resolve(provider: nil, cliHint: nil) == nil)
    }

    @Test("추가·삭제가 목록을 갱신한다")
    func addAndRemove() {
        var hint = VocabularyHint()
        hint.add(" 똑닥 ")
        hint.add("")
        hint.add("똑닥")
        hint.add("홍길동")
        #expect(hint.terms == ["똑닥", "홍길동"])
        hint.remove("똑닥")
        #expect(hint.terms == ["홍길동"])
        hint.remove(at: 0)
        #expect(hint.terms.isEmpty)
    }
}

@Suite("인식 힌트 저장소")
struct VocabularyStoreTests {
    private func makeStore() -> (store: VocabularyStore, suite: String, defaults: UserDefaults) {
        let suite = "vocabulary-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (VocabularyStore(defaults: defaults), suite, defaults)
    }

    private func tearDown(suite: String, defaults: UserDefaults) {
        defaults.removePersistentDomain(forName: suite)
    }

    @Test("저장된 값이 없으면 꺼져 있고 힌트도 없다 — 지금과 같다")
    func unsetDefaultsMatchCurrentBehavior() {
        let (store, suite, defaults) = makeStore()
        defer { tearDown(suite: suite, defaults: defaults) }
        #expect(!store.isEnabled)
        #expect(store.terms.isEmpty)
        #expect(store.transcriptionHint == nil)
    }

    @Test("꺼져 있으면 저장한 용어를 엔진에 넘기지 않는다")
    func storedTermsStayLocalWhileOff() {
        let (store, suite, defaults) = makeStore()
        defer { tearDown(suite: suite, defaults: defaults) }
        store.addTerm("똑닥")
        store.addTerm("홍길동")
        #expect(store.terms == ["똑닥", "홍길동"])
        #expect(!store.isEnabled)
        #expect(store.transcriptionHint == nil)
    }

    @Test("켜져 있을 때만 용어가 전사 힌트로 넘어간다")
    func passesTermsOnlyWhenEnabled() {
        let (store, suite, defaults) = makeStore()
        defer { tearDown(suite: suite, defaults: defaults) }
        store.terms = ["똑닥", "person", "TICKET-12"]
        #expect(store.transcriptionHint == nil)

        store.isEnabled = true
        #expect(store.transcriptionHint == "똑닥, person, TICKET-12")

        store.isEnabled = false
        #expect(store.transcriptionHint == nil)
        #expect(store.terms == ["똑닥", "person", "TICKET-12"])
    }

    @Test("추가·삭제가 로컬 저장소에 남는다")
    func addRemovePersists() {
        let (store, suite, defaults) = makeStore()
        defer { tearDown(suite: suite, defaults: defaults) }
        #expect(store.addTerm(" 똑닥 "))
        #expect(!store.addTerm("똑닥"))
        store.addTerm("홍길동")
        store.removeTerm("똑닥")

        let reloaded = VocabularyStore(defaults: defaults)
        #expect(reloaded.terms == ["홍길동"])
    }
}
