import Foundation

/// 최종 생성 프롬프트와 응답 파서가 **같은 번호**를 보게 만드는 카탈로그.
/// 모델은 근거를 새로 만들지 않고 번호만 참조하므로 근거 위조가 원천적으로 불가능하다.
public struct FactCatalog: Sendable {
    public private(set) var ordered: [MeetingFact.Kind: [MeetingFact]] = [:]

    public init(facts: [MeetingFact]) {
        for kind in MeetingFact.Kind.allCases {
            ordered[kind] = facts.filter { $0.kind == kind && !$0.discarded }
        }
    }

    public func facts(_ kind: MeetingFact.Kind) -> [MeetingFact] {
        ordered[kind] ?? []
    }

    /// 1부터 시작하는 번호로 후보를 찾는다.
    public func fact(_ kind: MeetingFact.Kind, number: Int) -> MeetingFact? {
        let list = facts(kind)
        guard number >= 1, number <= list.count else { return nil }
        return list[number - 1]
    }

    /// 번호가 잘못 왔을 때 내용 유사도로 후보를 찾는다.
    public func bestMatch(_ kind: MeetingFact.Kind, content: String, threshold: Double = 0.5) -> MeetingFact? {
        facts(kind)
            .map { ($0, TextSimilarity.overlap($0.content, content)) }
            .filter { $0.1 >= threshold }
            .max { $0.1 < $1.1 }?
            .0
    }

    public func describe(_ kind: MeetingFact.Kind) -> String {
        let list = facts(kind)
        guard !list.isEmpty else { return "없음" }
        return list.enumerated().map { index, fact in
            var line = "\(index + 1). \(fact.content)"
            if let decisionKind = fact.decisionKind {
                line += " [상태: \(decisionKind.rawValue)]"
            }
            if let assignee = fact.assignee {
                line += " [담당: \(assignee)]"
            }
            if let dueDate = fact.dueDate {
                line += " [마감: \(dueDate)]"
            }
            if let note = fact.dueDateNote {
                line += " [일정 표현: \(note)]"
            }
            if let severity = fact.severity, severity != .unknown {
                line += " [심각도: \(severity.rawValue)]"
            }
            if !fact.evidence.isEmpty {
                let stamps = fact.evidence.map { TimeFormat.stamp($0.startTime) }
                line += " [근거 시각: \(stamps.joined(separator: ", "))]"
            }
            return line
        }.joined(separator: "\n")
    }
}
