import Foundation

/// 회의록의 한국어 기한 표현을 실제 날짜로 바꾼다.
///
/// Jira `duedate`는 `YYYY-MM-DD`만 받는다. 해석할 수 없으면 **날짜를 만들지 않고 nil을 돌려준다**.
/// 원문 표현은 이슈 본문에 남겨 사용자가 확인하게 한다.
public enum KoreanDateParser {
    /// - Parameters:
    ///   - text: "2026-03-12", "3월 12일", "3/12" 같은 표현
    ///   - reference: 연도가 없는 표현의 기준 날짜 (보통 회의 날짜)
    /// - Returns: 해석된 날짜. 상대 표현("다음 주 월요일")은 nil.
    public static func parse(_ text: String?, reference: Date, calendar: Calendar = .current) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }

        // 1. ISO 형식
        if let match = firstMatch("(\\d{4})[-./](\\d{1,2})[-./](\\d{1,2})", in: text) {
            return date(
                year: Int(match[1]),
                month: Int(match[2]),
                day: Int(match[3]),
                reference: reference,
                calendar: calendar
            )
        }
        // 2. "3월 12일"
        if let match = firstMatch("(\\d{1,2})\\s*월\\s*(\\d{1,2})\\s*일", in: text) {
            return rollForward(
                month: Int(match[1]),
                day: Int(match[2]),
                reference: reference,
                calendar: calendar
            )
        }
        // 3. "3/12"
        if let match = firstMatch("^(\\d{1,2})[/.](\\d{1,2})$", in: text) {
            return rollForward(
                month: Int(match[1]),
                day: Int(match[2]),
                reference: reference,
                calendar: calendar
            )
        }
        // 4. "오늘", "내일", "모레"
        switch text {
        case "오늘": return calendar.startOfDay(for: reference)
        case "내일": return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: reference))
        case "모레": return calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: reference))
        default: break
        }
        // 상대 표현("다음 주 월요일", "추후")은 확정하지 않는다.
        return nil
    }

    /// Jira에 넣을 `YYYY-MM-DD` 문자열
    public static func jiraDueDate(_ text: String?, reference: Date, calendar: Calendar = .current) -> String? {
        guard let date = parse(text, reference: reference, calendar: calendar) else { return nil }
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else { return nil }
        components = DateComponents()
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    // MARK: - 내부

    private static func firstMatch(_ pattern: String, in text: String) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (0 ..< match.numberOfRanges).map { match.substring(at: $0, in: text) }
    }

    private static func date(
        year: Int?,
        month: Int?,
        day: Int?,
        reference _: Date,
        calendar: Calendar
    ) -> Date? {
        guard let year, let month, let day, (1 ... 12).contains(month), (1 ... 31).contains(day) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components)
    }

    /// 연도가 없는 표현은 기준 날짜의 연도를 쓰고, 이미 지난 날짜면 다음 해로 넘긴다.
    private static func rollForward(
        month: Int?,
        day: Int?,
        reference: Date,
        calendar: Calendar
    ) -> Date? {
        guard let month, let day else { return nil }
        let referenceYear = calendar.component(.year, from: reference)
        guard let candidate = date(year: referenceYear, month: month, day: day, reference: reference, calendar: calendar)
        else { return nil }
        if candidate >= calendar.startOfDay(for: reference) { return candidate }
        return date(year: referenceYear + 1, month: month, day: day, reference: reference, calendar: calendar)
    }
}

extension Int {
    init?(_ value: String?) {
        guard let value, let parsed = Int(value) else { return nil }
        self = parsed
    }
}
