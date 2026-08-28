import Foundation

/// 음성 인식에 넘기는 고유명사·약어 목록.
///
/// 힌트는 구간 분할을 거칠게 만들 수 있어 **기본은 꺼져 있다.**
/// 켜져 있을 때만 전사 엔진에 문자열을 넘기고, 꺼져 있으면 용어가 있어도 `nil`이다.
public struct VocabularyHint: Equatable, Hashable, Sendable {
    public var isEnabled: Bool
    public var terms: [String]

    public init(isEnabled: Bool = false, terms: [String] = []) {
        self.isEnabled = isEnabled
        self.terms = Self.normalized(terms)
    }

    /// 전사 엔진에 넘길 힌트. 꺼져 있거나 쓸 용어가 없으면 `nil`이라 지금과 같다.
    public var transcriptionHint: String? {
        guard isEnabled else { return nil }
        let cleaned = Self.normalized(terms)
        return cleaned.isEmpty ? nil : cleaned.joined(separator: ", ")
    }

    /// 전사 엔진이 쓸 힌트를 고른다.
    ///
    /// 설정 provider가 있으면 그 결과만 쓴다. 꺼져 있으면 `nil`이고 CLI 고정값으로 넘어가지 않는다.
    /// provider가 없으면 `--vocabulary`처럼 엔진에 박아 둔 값을 쓴다.
    public static func resolve(provider: (@Sendable () -> String?)?, cliHint: String?) -> String? {
        if let provider {
            return provider()
        }
        return cliHint
    }

    /// 앞뒤 공백을 버리고 빈 항목·중복을 제거한다. 처음 나온 순서를 지킨다.
    public static func normalized(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for term in terms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    /// 빈 문자열이면 무시한다. 이미 있으면 순서를 바꾸지 않는다.
    public mutating func add(_ term: String) {
        terms = Self.normalized(terms + [term])
    }

    public mutating func remove(_ term: String) {
        terms.removeAll { $0 == term }
    }

    public mutating func remove(at index: Int) {
        guard terms.indices.contains(index) else { return }
        terms.remove(at: index)
    }
}
