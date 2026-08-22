import Foundation

/// 회의록 마크다운을 화면에 그리기 위한 블록 단위.
///
/// 범용 마크다운 파서가 아니다. `MeetingNoteExporter.markdown`이 실제로 내보내는 문법
/// — `#`/`##` 제목, `- ` 목록, `|` 표, 문단 — 만 다룬다.
/// 미리보기와 내보내기 결과가 어긋나지 않도록 입력은 항상 내보내기 문자열을 그대로 쓴다.
public enum MarkdownBlock: Equatable, Sendable, Identifiable {
    case heading(level: Int, text: String)
    case bullet(text: String)
    /// `- [ ]` / `- [x]` 체크리스트 항목. Action Item에 쓴다.
    case checklist(text: String, done: Bool)
    case table(headers: [String], rows: [[String]])
    case paragraph(text: String)

    public var id: String {
        switch self {
        case let .heading(level, text): "h\(level):\(text)"
        case let .bullet(text): "li:\(text)"
        case let .checklist(text, done): "task:\(done):\(text)"
        case let .table(headers, rows): "table:\(headers.joined(separator: "|")):\(rows.count)"
        case let .paragraph(text): "p:\(text)"
        }
    }
}

public enum MarkdownBlockParser {
    /// 마크다운 문자열을 블록으로 나눈다. 빈 줄은 버리고 내용은 하나도 버리지 않는다.
    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = markdown.components(separatedBy: .newlines)
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if let heading = heading(from: trimmed) {
                blocks.append(heading)
                index += 1
                continue
            }

            if isTableRow(trimmed) {
                let (table, consumed) = parseTable(lines, from: index)
                blocks.append(table)
                index += consumed
                continue
            }

            if trimmed.hasPrefix("- ") {
                let body = String(trimmed.dropFirst(2))
                if let task = checklist(from: body) {
                    blocks.append(task)
                } else {
                    blocks.append(.bullet(text: body))
                }
                index += 1
                continue
            }

            blocks.append(.paragraph(text: trimmed))
            index += 1
        }
        return blocks
    }

    private static func heading(from line: String) -> MarkdownBlock? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix { $0 == "#" }.count
        let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return .heading(level: hashes, text: text)
    }

    /// `[ ] 할 일` / `[x] 한 일` 형태인지.
    private static func checklist(from body: String) -> MarkdownBlock? {
        let markers: [(String, Bool)] = [("[ ] ", false), ("[x] ", true), ("[X] ", true)]
        for (marker, done) in markers where body.hasPrefix(marker) {
            return .checklist(text: String(body.dropFirst(marker.count)), done: done)
        }
        return nil
    }

    private static func isTableRow(_ line: String) -> Bool {
        line.hasPrefix("|") && line.hasSuffix("|") && line.count > 1
    }

    /// 구분선(`| --- |`)인지. 표의 머리글과 본문을 가르는 줄이며 화면에는 그리지 않는다.
    private static func isSeparatorRow(_ cells: [String]) -> Bool {
        !cells.isEmpty && cells.allSatisfy { cell in
            !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " }
        }
    }

    private static func cells(of line: String) -> [String] {
        line
            .trimmingCharacters(in: .whitespaces)
            .dropFirst()
            .dropLast()
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// 이어지는 표 줄을 한 블록으로 모은다. 반환값의 두 번째는 소비한 줄 수다.
    private static func parseTable(_ lines: [String], from start: Int) -> (MarkdownBlock, Int) {
        var headers: [String] = []
        var rows: [[String]] = []
        var index = start

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard isTableRow(trimmed) else { break }
            let row = cells(of: trimmed)
            if isSeparatorRow(row) {
                index += 1
                continue
            }
            if headers.isEmpty {
                headers = row
            } else {
                rows.append(row)
            }
            index += 1
        }
        return (.table(headers: headers, rows: rows), index - start)
    }
}
