import Foundation

/// LLM 출력에 관용적인 JSON 표현.
/// 필드 누락, 타입 흔들림(숫자를 문자열로 출력 등), 키 표기 차이(snake/camel)를 흡수한다(§10).
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: - 파싱

    public static func parse(_ text: String) throws -> JSONValue {
        guard let data = text.data(using: .utf8) else { throw StructuredOutputError.notUTF8 }
        let raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return JSONValue(any: raw)
    }

    public init(any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let value as Bool where type(of: any) == type(of: true):
            self = .bool(value)
        case let value as NSNumber:
            // NSNumber는 Bool도 포함한다. CFBoolean 여부로 구분한다.
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else {
                self = .number(value.doubleValue)
            }
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .array(value.map { JSONValue(any: $0) })
        case let value as [String: Any]:
            self = .object(value.mapValues { JSONValue(any: $0) })
        default:
            self = .null
        }
    }

    // MARK: - 관용적 접근

    /// 키 조회. 정확 일치 → 대소문자 무시 → snake/camel 변환 순으로 찾는다.
    public subscript(_ keys: String...) -> JSONValue {
        guard case let .object(dictionary) = self else { return .null }
        for key in keys {
            if let value = dictionary[key] {
                return value
            }
            let normalizedKey = JSONValue.normalizeKey(key)
            if let match = dictionary.first(where: { JSONValue.normalizeKey($0.key) == normalizedKey }) {
                return match.value
            }
        }
        return .null
    }

    private static func normalizeKey(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    public var isNull: Bool {
        switch self {
        case .null: true
        case let .string(value):
            // 모델이 null 대신 "null", "N/A", "미정" 등을 넣는 경우를 결측으로 취급한다.
            JSONValue.nullLikeStrings.contains(value.trimmingCharacters(in: .whitespaces).lowercased())
        default: false
        }
    }

    static let nullLikeStrings: Set<String> = [
        "", "null", "nil", "none", "n/a", "na", "unknown", "미정", "미확정", "없음", "해당 없음", "-"
    ]

    /// 문자열로 변환. 숫자·불리언도 문자열로 받는다. 결측이면 nil.
    public var stringValue: String? {
        switch self {
        case let .string(value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return isNull ? nil : (trimmed.isEmpty ? nil : trimmed)
        case let .number(value):
            return value == value.rounded() ? String(Int(value)) : String(value)
        case let .bool(value):
            return value ? "true" : "false"
        default:
            return nil
        }
    }

    /// 숫자로 변환. "0.8", "80%" 같은 문자열도 처리한다.
    public var doubleValue: Double? {
        switch self {
        case let .number(value): return value
        case let .bool(value): return value ? 1 : 0
        case let .string(value):
            var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            var isPercent = false
            if text.hasSuffix("%") {
                isPercent = true
                text.removeLast()
            }
            guard let parsed = Double(text.trimmingCharacters(in: .whitespaces)) else { return nil }
            return isPercent ? parsed / 100 : parsed
        default: return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case let .bool(value): value
        case let .number(value): value != 0
        case let .string(value):
            switch value.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "yes", "y", "1", "예", "네": true
            case "false", "no", "n", "0", "아니오", "아니요": false
            default: nil
            }
        default: nil
        }
    }

    /// 배열로 변환. 단일 객체가 오면 1개 원소 배열로 취급한다.
    public var arrayValue: [JSONValue] {
        switch self {
        case let .array(values): values
        case .null: []
        default: isNull ? [] : [self]
        }
    }

    public var objectValue: [String: JSONValue]? {
        if case let .object(dictionary) = self {
            return dictionary
        }
        return nil
    }

    /// 0...1 범위로 정리한 신뢰도. 1보다 큰 값(0~100 스케일)은 100으로 나눈다.
    public var confidenceValue: Double? {
        guard var value = doubleValue else { return nil }
        if value > 1 {
            value /= 100
        }
        return min(1, max(0, value))
    }
}

public enum StructuredOutputError: Error, LocalizedError, Sendable, Equatable {
    case notUTF8
    case noJSONFound(rawPrefix: String)
    case decodingFailed(String)
    case schemaViolation([String])

    public var errorDescription: String? {
        switch self {
        case .notUTF8: "모델 출력을 UTF-8로 해석할 수 없습니다."
        case let .noJSONFound(prefix): "모델 출력에서 JSON을 찾지 못했습니다: \(prefix)"
        case let .decodingFailed(message): "JSON 파싱 실패: \(message)"
        case let .schemaViolation(problems): "JSON 스키마 위반: \(problems.joined(separator: ", "))"
        }
    }
}
