import Foundation

/// 한국어 조사 선택. 종성 유무로 을/를, 이/가, 은/는을 고른다.
public enum KoreanParticle {
    /// 마지막 글자에 종성이 있는지
    public static func hasFinalConsonant(_ text: String) -> Bool? {
        guard let last = text.unicodeScalars.reversed().first(where: { !CharacterSet.whitespaces.contains($0) })
        else { return nil }
        let value = last.value
        // 한글 음절 영역
        if (0xAC00 ... 0xD7A3).contains(value) {
            return (value - 0xAC00) % 28 != 0
        }
        // 숫자는 읽는 소리 기준
        if let digit = Character(last).wholeNumberValue, (0 ... 9).contains(digit) {
            return [0, 1, 3, 6, 7, 8].contains(digit) // 영·일·삼·육·칠·팔
        }
        // 영문은 자음으로 끝나면 종성 있는 것으로 본다
        if Character(last).isLetter {
            let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
            return !vowels.contains(Character(String(last).lowercased()))
        }
        return nil
    }

    public static func objective(after text: String) -> String {
        switch hasFinalConsonant(text) {
        case .some(true): "을"
        case .some(false): "를"
        case nil: "를"
        }
    }

    public static func subjective(after text: String) -> String {
        switch hasFinalConsonant(text) {
        case .some(true): "이"
        case .some(false): "가"
        case nil: "가"
        }
    }

    public static func topic(after text: String) -> String {
        switch hasFinalConsonant(text) {
        case .some(true): "은"
        case .some(false): "는"
        case nil: "는"
        }
    }
}
