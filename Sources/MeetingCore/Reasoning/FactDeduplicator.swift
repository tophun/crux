import Foundation

/// 반복 발언 통합(§9).
/// 같은 내용이 여러 번 나오면 한 번만 기록하되, 담당자·마감일·결정·리스크가 바뀌면 바뀐 내용을 남긴다.
public struct FactDeduplicator: Sendable {
    public struct Result: Sendable {
        public var facts: [MeetingFact]
        public var mergedCount: Int
        /// 통합 과정에서 발견된 변화·충돌 기록. 사고 모드 재검토 신호로 쓴다.
        public var changeLog: [String]
    }

    /// 같은 내용으로 볼 유사도 임계
    public var similarityThreshold: Double

    public init(similarityThreshold: Double = 0.6) {
        self.similarityThreshold = similarityThreshold
    }

    public func merge(_ facts: [MeetingFact]) -> Result {
        var groups: [[MeetingFact]] = []

        for fact in facts.sorted(by: Self.chronological) {
            if let index = groups.firstIndex(where: { group in
                group.contains { candidate in
                    candidate.kind == fact.kind
                        && TextSimilarity.overlap(candidate.content, fact.content) >= similarityThreshold
                }
            }) {
                groups[index].append(fact)
            } else {
                groups.append([fact])
            }
        }

        var merged: [MeetingFact] = []
        var mergedCount = 0
        var changeLog: [String] = []

        for group in groups {
            guard group.count > 1 else {
                merged.append(group[0])
                continue
            }
            mergedCount += group.count - 1
            let (fact, changes) = collapse(group)
            merged.append(fact)
            changeLog += changes
        }

        return Result(facts: merged.sorted(by: Self.chronological), mergedCount: mergedCount, changeLog: changeLog)
    }

    /// 그룹을 하나로 합친다. 뒤에 나온 발언이 이긴다(최종 합의 우선).
    func collapse(_ group: [MeetingFact]) -> (MeetingFact, [String]) {
        let ordered = group.sorted(by: Self.chronological)
        var result = ordered.last!
        var changes: [String] = []
        var notes = Set(result.ambiguityNotes)

        // 근거는 모두 합친다.
        var evidence: [Evidence] = []
        var seen: Set<String> = []
        for fact in ordered {
            for item in fact.evidence {
                let key = item.segmentId + "|" + item.quote
                if seen.insert(key).inserted { evidence.append(item) }
            }
        }
        result.evidence = evidence.sorted { $0.startTime < $1.startTime }

        // 변화 감지
        let assignees = ordered.compactMap(\.assignee)
        if Set(assignees).count > 1, let first = assignees.first, let last = assignees.last, first != last {
            changes.append("담당자 변경: \(first) → \(last)")
            notes.insert("담당자가 회의 중 변경됨")
        }
        if result.assignee == nil, let latest = assignees.last {
            // 뒤 발언에 담당자가 빠졌더라도 앞에서 확인된 담당자는 유지한다.
            result.assignee = latest
        }

        let dueDates = ordered.compactMap(\.dueDate)
        if Set(dueDates).count > 1, let first = dueDates.first, let last = dueDates.last, first != last {
            changes.append("마감일 변경: \(first) → \(last)")
            notes.insert("마감일이 회의 중 변경됨")
        }
        if result.dueDate == nil, let latest = dueDates.last {
            result.dueDate = latest
        }
        if result.dueDateNote == nil {
            result.dueDateNote = ordered.compactMap(\.dueDateNote).last
        }

        let kinds = ordered.compactMap(\.decisionKind)
        if Set(kinds).count > 1 {
            changes.append("결정 상태 변경: \(kinds.map(\.rawValue).joined(separator: " → "))")
            notes.insert("제안에서 결정으로(또는 반대로) 상태가 바뀜")
        }

        // 신뢰도는 근거가 늘었으므로 가장 높은 값을 쓴다.
        result.confidence = ordered.map(\.confidence).max() ?? result.confidence
        result.ambiguityNotes = Array(notes).sorted()
        return (result, changes)
    }

    static func chronological(_ lhs: MeetingFact, _ rhs: MeetingFact) -> Bool {
        let left = lhs.evidence.map(\.startTime).min() ?? TimeInterval(lhs.windowIndex) * 1000
        let right = rhs.evidence.map(\.startTime).min() ?? TimeInterval(rhs.windowIndex) * 1000
        if left == right { return lhs.windowIndex < rhs.windowIndex }
        return left < right
    }
}
