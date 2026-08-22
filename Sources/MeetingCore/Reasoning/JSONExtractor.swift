import Foundation

/// 모델 출력에서 JSON 본문을 뽑아내고 흔한 오류를 자동 복구한다(§10).
///
/// 복구 순서
///   1. 사고 블록 제거
///   2. 코드 펜스 제거
///   3. 중괄호/대괄호 균형을 맞춰 최외곽 JSON 추출 (문자열·이스케이프 인식)
///   4. 스마트 쿼트, 트ailing comma, 주석, 잘린 끝 보정
public enum JSONExtractor {
    public struct Extraction: Sendable {
        public var value: JSONValue
        /// 자동 복구가 적용됐는지 (품질 로그용)
        public var repaired: Bool
        public var appliedFixes: [String]
    }

    public static func extract(from raw: String) throws -> Extraction {
        let stripped = ThinkingStripper.strip(raw).visibleText
        let defenced = removeCodeFences(stripped)

        var fixes: [String] = []

        // 1차: 그대로 파싱
        if let candidate = firstBalancedJSON(in: defenced) {
            if let value = try? JSONValue.parse(candidate) {
                return Extraction(value: value, repaired: false, appliedFixes: [])
            }
            // 2차: 정규화 후 파싱
            let (normalized, applied) = normalize(candidate)
            fixes += applied
            if let value = try? JSONValue.parse(normalized) {
                return Extraction(value: value, repaired: true, appliedFixes: fixes)
            }
            // 3차: 잘린 JSON 닫기
            let (closed, closeFixes) = closeTruncated(normalized)
            fixes += closeFixes
            if let value = try? JSONValue.parse(closed) {
                return Extraction(value: value, repaired: true, appliedFixes: fixes)
            }
            throw StructuredOutputError.decodingFailed(String(closed.prefix(200)))
        }

        // 균형 잡힌 JSON이 없으면 잘린 출력일 수 있다. 첫 여는 괄호부터 강제로 닫아 본다.
        if let start = defenced.firstIndex(where: { $0 == "{" || $0 == "[" }) {
            let tail = String(defenced[start...])
            let (normalized, applied) = normalize(tail)
            let (closed, closeFixes) = closeTruncated(normalized)
            fixes += applied + closeFixes
            if let value = try? JSONValue.parse(closed) {
                return Extraction(value: value, repaired: true, appliedFixes: fixes)
            }
        }

        throw StructuredOutputError.noJSONFound(rawPrefix: String(defenced.prefix(200)))
    }

    // MARK: - 단계별 처리

    static func removeCodeFences(_ text: String) -> String {
        guard text.contains("```") else { return text }
        var result = ""
        var insideFence = false
        var sawFencedContent = false
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                insideFence.toggle()
                continue
            }
            if insideFence {
                sawFencedContent = true
                result += line + "\n"
            }
        }
        return sawFencedContent ? result : text.replacingOccurrences(of: "```", with: "")
    }

    /// 문자열 리터럴과 이스케이프를 인식하면서 균형 잡힌 첫 JSON 블록을 찾는다.
    static func firstBalancedJSON(in text: String) -> String? {
        let characters = Array(text)
        guard let startIndex = characters.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        let opening = characters[startIndex]
        let closing: Character = opening == "{" ? "}" : "]"

        var depth = 0
        var inString = false
        var escaped = false

        for index in startIndex ..< characters.count {
            let character = characters[index]
            if escaped {
                escaped = false
                continue
            }
            if character == "\\", inString {
                escaped = true
                continue
            }
            if character == "\"" {
                inString.toggle()
                continue
            }
            guard !inString else { continue }
            if character == opening {
                depth += 1
            } else if character == closing {
                depth -= 1
                if depth == 0 {
                    return String(characters[startIndex ... index])
                }
            }
        }
        return nil
    }

    static func normalize(_ text: String) -> (String, [String]) {
        var result = text
        var fixes: [String] = []

        let smartQuotes: [(String, String)] = [
            ("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{2018}", "'"), ("\u{2019}", "'")
        ]
        for (from, to) in smartQuotes where result.contains(from) {
            result = result.replacingOccurrences(of: from, with: to)
            if !fixes.contains("smart-quotes") { fixes.append("smart-quotes") }
        }

        if let stripped = removeLineComments(result), stripped != result {
            result = stripped
            fixes.append("comments")
        }

        if let stripped = removeTrailingCommas(result), stripped != result {
            result = stripped
            fixes.append("trailing-comma")
        }

        return (result, fixes)
    }

    /// 문자열 밖의 `//` 주석을 제거한다.
    static func removeLineComments(_ text: String) -> String? {
        guard text.contains("//") else { return text }
        var output = ""
        var inString = false
        var escaped = false
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if escaped {
                output.append(character)
                escaped = false
                index += 1
                continue
            }
            if character == "\\", inString {
                output.append(character)
                escaped = true
                index += 1
                continue
            }
            if character == "\"" {
                inString.toggle()
                output.append(character)
                index += 1
                continue
            }
            if !inString, character == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                while index < characters.count, characters[index] != "\n" {
                    index += 1
                }
                continue
            }
            output.append(character)
            index += 1
        }
        return output
    }

    /// `,]` `,}` 형태의 trailing comma를 제거한다.
    static func removeTrailingCommas(_ text: String) -> String? {
        var output = ""
        var inString = false
        var escaped = false
        var pendingComma = false
        for character in text {
            if escaped {
                output.append(character)
                escaped = false
                continue
            }
            if character == "\\", inString {
                output.append(character)
                escaped = true
                continue
            }
            if character == "\"" {
                if pendingComma {
                    output.append(",")
                    pendingComma = false
                }
                inString.toggle()
                output.append(character)
                continue
            }
            if inString {
                output.append(character)
                continue
            }
            if pendingComma {
                if character == "]" || character == "}" {
                    pendingComma = false
                    output.append(character)
                    continue
                }
                if character.isWhitespace {
                    continue
                }
                output.append(",")
                pendingComma = false
                output.append(character)
                continue
            }
            if character == "," {
                pendingComma = true
                continue
            }
            output.append(character)
        }
        if pendingComma { output.append(",") }
        return output
    }

    /// 토큰 한계로 잘린 JSON의 열린 문자열·괄호를 닫는다.
    static func closeTruncated(_ text: String) -> (String, [String]) {
        var stack: [Character] = []
        var inString = false
        var escaped = false

        for character in text {
            if escaped { escaped = false; continue }
            if character == "\\" && inString { escaped = true; continue }
            if character == "\"" { inString.toggle(); continue }
            guard !inString else { continue }
            if character == "{" || character == "[" {
                stack.append(character)
            } else if character == "}" || character == "]" {
                if !stack.isEmpty { stack.removeLast() }
            }
        }

        guard inString || !stack.isEmpty else { return (text, []) }

        var result = text
        var fixes: [String] = []
        // 잘린 마지막 값은 신뢰할 수 없으므로 열린 문자열은 닫아서 버릴 수 있게 한다.
        if inString {
            result.append("\"")
            fixes.append("close-string")
        }
        // 마지막 쉼표는 제거
        while let last = result.last, last == "," || last.isWhitespace {
            result.removeLast()
        }
        while let opening = stack.popLast() {
            result.append(opening == "{" ? "}" : "]")
        }
        fixes.append("close-brackets")
        return (result, fixes)
    }
}
