import Foundation

/// 윤문 처리 경로. 사용자가 고르지 않고 탐지 결과로 앱이 정한다.
public enum KoreanEditorMode: String, Sendable, Codable, CaseIterable {
    /// 보수적 — 규칙 기반 치환만 (탐지가 적거나 텍스트가 짧을 때)
    case conservative
    /// 일반 — 규칙 치환 + LLM 국소 윤문 1회
    case standard
    /// 정밀 — 규칙 치환 + LLM 윤문 + 잔존 S1 재처리
    case strict

    public var displayName: String {
        switch self {
        case .conservative: "보수적"
        case .standard: "일반"
        case .strict: "정밀"
        }
    }
}

/// `korean-meeting-editor` Skill.
///
/// 회의록의 **문장만** 다듬는다. 근거 인용문·담당자·기한·수치는 입력에서 제외한다.
/// 인용문을 건드리면 근거 검증 체계가 무너지기 때문이다.
///
/// 이식 출처: `im-not-ai`(MIT), `fluent-korean`(MIT). 자세한 내용은 docs/SKILLS.md.
public struct KoreanMeetingEditor: Sendable {
    public struct Configuration: Sendable {
        /// 이 변경률을 넘으면 경고를 남긴다.
        public var warnChangeRate: Double
        /// 이 변경률을 넘으면 해당 필드를 롤백한다.
        public var rollbackChangeRate: Double
        /// LLM 윤문에 쓸 최대 토큰
        public var maxTokens: Int
        /// 이 길이보다 짧은 텍스트는 LLM 윤문을 하지 않는다.
        public var minimumLengthForLLM: Int

        public init(
            warnChangeRate: Double = 0.30,
            rollbackChangeRate: Double = 0.50,
            maxTokens: Int = 1024,
            minimumLengthForLLM: Int = 40
        ) {
            self.warnChangeRate = warnChangeRate
            self.rollbackChangeRate = rollbackChangeRate
            self.maxTokens = maxTokens
            self.minimumLengthForLLM = minimumLengthForLLM
        }
    }

    public struct FieldOutcome: Hashable, Sendable, Codable {
        public var field: String
        public var changeRate: Double
        public var appliedRuleIds: [String]
        public var remainingSeverities: [KoreanTellSeverity]
        public var rolledBack: Bool
        public var rollbackReason: String?
    }

    public struct Report: Hashable, Sendable, Codable {
        public var mode: KoreanEditorMode
        public var detectedSpanCount: Int
        public var editedFieldCount: Int
        public var rolledBackFieldCount: Int
        public var outcomes: [FieldOutcome]
        public var warnings: [String]

        public var averageChangeRate: Double {
            guard !outcomes.isEmpty else { return 0 }
            return outcomes.map(\.changeRate).reduce(0, +) / Double(outcomes.count)
        }
    }

    public var configuration: Configuration
    private let polisher: KoreanTextPolisher

    public init(configuration: Configuration = Configuration(), polisher: KoreanTextPolisher = KoreanTextPolisher()) {
        self.configuration = configuration
        self.polisher = polisher
    }

    /// 탐지 밀도로 처리 경로를 정한다. 사용자에게 노출하지 않는다.
    public func selectMode(for note: MeetingNote) -> KoreanEditorMode {
        let fields = Self.editableFields(of: note)
        let totalCharacters = fields.reduce(0) { $0 + $1.value.count }
        let spans = fields.flatMap { polisher.detect(in: $0.value) }
        let s1Count = spans.count(where: { $0.severity == .s1 })

        if totalCharacters < 120 || spans.isEmpty {
            return .conservative
        }
        if s1Count >= 3 || spans.count >= 8 {
            return .strict
        }
        return .standard
    }

    /// 회의록을 윤문한다. `model`이 nil이면 규칙 기반만 적용한다.
    public func edit(
        note: MeetingNote,
        model: (any LocalLanguageModel)? = nil
    ) async -> (note: MeetingNote, report: Report) {
        let mode = model == nil ? .conservative : selectMode(for: note)
        var edited = note
        var outcomes: [FieldOutcome] = []
        var warnings: [String] = []
        var detectedTotal = 0

        for field in Self.editableFields(of: note) {
            let original = field.value
            guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            let detected = polisher.detect(in: original)
            detectedTotal += detected.count

            var candidate = polisher.polish(original)
            var rolledBack = false
            var rollbackReason: String?

            if mode != .conservative,
               let model,
               original.count >= configuration.minimumLengthForLLM,
               !candidate.remaining.isEmpty {
                if let refined = await refine(
                    text: candidate.text,
                    spans: candidate.remaining,
                    model: model
                ) {
                    let rate = ChangeRate.between(original, refined)
                    let anchors = ContentAnchor.check(original: original, revised: refined)
                    if rate > configuration.rollbackChangeRate {
                        rolledBack = true
                        rollbackReason = String(format: "변경률 %.0f%% 초과로 롤백", configuration.rollbackChangeRate * 100)
                    } else if !anchors.isPreserved {
                        rolledBack = true
                        rollbackReason = "내용 앵커 손실로 롤백: \(anchors.missing.prefix(3).joined(separator: ", "))"
                    } else {
                        candidate = KoreanTextPolisher.Result(
                            text: refined,
                            appliedRuleIds: candidate.appliedRuleIds,
                            remaining: polisher.detect(in: refined),
                            changeRate: rate
                        )
                        // 정밀 경로: S1이 남아 있으면 한 번 더 시도한다.
                        if mode == .strict, candidate.remaining.contains(where: { $0.severity == .s1 }) {
                            if let second = await refine(
                                text: candidate.text,
                                spans: candidate.remaining.filter { $0.severity == .s1 },
                                model: model
                            ) {
                                let secondRate = ChangeRate.between(original, second)
                                let secondAnchors = ContentAnchor.check(original: original, revised: second)
                                if secondRate <= configuration.rollbackChangeRate, secondAnchors.isPreserved {
                                    candidate = KoreanTextPolisher.Result(
                                        text: second,
                                        appliedRuleIds: candidate.appliedRuleIds,
                                        remaining: polisher.detect(in: second),
                                        changeRate: secondRate
                                    )
                                }
                            }
                        }
                    }
                }
            }

            let finalText = rolledBack ? polisher.polish(original).text : candidate.text
            let finalRate = ChangeRate.between(original, finalText)

            if finalRate > configuration.warnChangeRate, !rolledBack {
                warnings.append(
                    String(format: "%@ 변경률 %.0f%% — 검토 필요", field.name, finalRate * 100)
                )
            }

            if finalText != original {
                field.apply(finalText, &edited)
            }

            outcomes.append(
                FieldOutcome(
                    field: field.name,
                    changeRate: finalRate,
                    appliedRuleIds: candidate.appliedRuleIds,
                    remainingSeverities: polisher.detect(in: finalText).map(\.severity),
                    rolledBack: rolledBack,
                    rollbackReason: rollbackReason
                )
            )
        }

        let report = Report(
            mode: mode,
            detectedSpanCount: detectedTotal,
            editedFieldCount: outcomes.count(where: { $0.changeRate > 0 }),
            rolledBackFieldCount: outcomes.filter(\.rolledBack).count,
            outcomes: outcomes,
            warnings: warnings
        )
        return (edited, report)
    }

    // MARK: - LLM 국소 윤문

    private func refine(
        text: String,
        spans: [KoreanTellSpan],
        model: any LocalLanguageModel
    ) async -> String? {
        let prompt = Self.prompt(text: text, spans: spans)
        guard let raw = try? await model.generate(
            systemPrompt: Self.systemPrompt,
            prompt: prompt,
            mode: .nonThinking,
            maxTokens: configuration.maxTokens
        ) else { return nil }

        let cleaned = Self.extractText(from: raw)
        guard !cleaned.isEmpty else { return nil }
        // 길이가 절반 미만이거나 두 배 초과면 지시를 벗어난 것으로 본다.
        guard cleaned.count >= text.count / 2, cleaned.count <= text.count * 2 else { return nil }
        return cleaned
    }

    static let systemPrompt = """
    당신은 한국어 회의록의 문장만 다듬는 편집자다.

    반드시 지킬 규칙:
    1. 내용을 바꾸지 않는다. 사실, 수치, 날짜, 고유명사, 제품명, 담당자 이름, 인용은 한 글자도 바꾸지 않는다.
    2. 문장을 새로 만들거나 없던 정보를 넣지 않는다. 비유나 수사도 새로 넣지 않는다.
    3. 지적된 표현만 고친다. 지적되지 않은 부분은 그대로 둔다.
    4. 격식은 원문과 같게 유지한다. 원문이 "합니다"면 "합니다"로, "다"면 "다"로 끝낸다.
    5. 결과는 다듬은 문장만 출력한다. 설명, 머리말, 따옴표, 코드펜스를 붙이지 않는다.
    """

    static func prompt(text: String, spans: [KoreanTellSpan]) -> String {
        var lines: [String] = []
        var seen: Set<String> = []
        for span in spans {
            let key = span.ruleId
            guard seen.insert(key).inserted else { continue }
            lines.append("- \"\(span.text)\": \(span.prescription)")
        }
        return """
        아래 문장에서 지적된 표현만 자연스러운 한국어로 고쳐라.

        원문:
        \(text)

        고칠 표현:
        \(lines.joined(separator: "\n"))

        다듬은 문장만 출력하라.
        """
    }

    static func extractText(from raw: String) -> String {
        var text = ThinkingStripper.strip(raw).visibleText
        text = text.replacingOccurrences(of: "```", with: "")
        // 모델이 머리말을 붙이는 경우 제거
        for prefix in ["다듬은 문장:", "결과:", "수정문:", "윤문 결과:"] {
            if let range = text.range(of: prefix) {
                text = String(text[range.upperBound...])
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 앞뒤 따옴표 제거
        if trimmed.count > 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    // MARK: - 편집 대상 필드

    /// 윤문 대상 필드. 근거 인용문·담당자·기한은 포함하지 않는다.
    struct EditableField {
        var name: String
        var value: String
        var apply: (String, inout MeetingNote) -> Void
    }

    static func editableFields(of note: MeetingNote) -> [EditableField] {
        var fields: [EditableField] = [
            EditableField(name: "title", value: note.title) { value, note in note.title = value },
            EditableField(name: "summary", value: note.summary) { value, note in note.summary = value }
        ]
        for (index, decision) in note.decisions.enumerated() {
            fields.append(
                EditableField(name: "decisions[\(index)]", value: decision.content) { value, note in
                    guard index < note.decisions.count else { return }
                    note.decisions[index].content = value
                }
            )
        }
        for (index, item) in note.actionItems.enumerated() {
            fields.append(
                EditableField(name: "actionItems[\(index)]", value: item.task) { value, note in
                    guard index < note.actionItems.count else { return }
                    note.actionItems[index].task = value
                }
            )
        }
        for (index, question) in note.openQuestions.enumerated() {
            fields.append(
                EditableField(name: "openQuestions[\(index)]", value: question.question) { value, note in
                    guard index < note.openQuestions.count else { return }
                    note.openQuestions[index].question = value
                }
            )
        }
        for (index, risk) in note.risks.enumerated() {
            fields.append(
                EditableField(name: "risks[\(index)]", value: risk.content) { value, note in
                    guard index < note.risks.count else { return }
                    note.risks[index].content = value
                }
            )
        }
        for (index, topic) in note.topics.enumerated() {
            fields.append(
                EditableField(name: "topics[\(index)].summary", value: topic.summary) { value, note in
                    guard index < note.topics.count else { return }
                    note.topics[index].summary = value
                }
            )
        }
        return fields
    }
}
