import Foundation

/// 검증이 끝난 회의록을 사용자 프롬프트대로 다시 구성한다.
///
/// 재료는 근거 검증을 통과한 회의록 내용뿐이다. 전사문·근거 인용·타임스탬프는 주지 않으므로
/// 어떤 프롬프트를 쓰든 문서에 새 사실이 생기거나 내부 데이터가 새어 나가지 않는다.
/// 결과는 마크다운 문서 하나이며, 실패하면 nil을 돌려 기본 구성을 쓰게 한다.
public enum DocumentComposer {
    /// 프롬프트가 사실상 비어 있으면 구성 단계를 건너뛴다.
    public static func isUsable(prompt: String) -> Bool {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines).count >= 5
    }

    public static func buildPrompt(note: MeetingNote, meeting: Meeting?, userPrompt: String) -> (system: String, user: String) {
        let facts = MeetingNoteExporter.markdown(note, meeting: meeting)
        let system = """
        너는 회의록 편집자다. 아래 규칙을 반드시 지켜라.
        - 제공된 회의록 내용만 사용한다. 없는 사실·이름·날짜를 만들지 않는다.
        - 확정되지 않은 값(미확정)은 그대로 미확정으로 둔다.
        - 결과는 마크다운 문서 본문만 출력한다. 설명이나 인사말을 붙이지 않는다.
        """
        let user = """
        [문서 구성 지시]
        \(userPrompt.trimmingCharacters(in: .whitespacesAndNewlines))

        [회의록 내용]
        \(facts)
        """
        return (system, user)
    }

    /// 모델 출력에서 문서만 남긴다. 비거나 지시를 되풀이한 출력은 버린다.
    public static func clean(_ output: String) -> String? {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // 코드 블록으로 감싸 돌려주는 경우가 있다.
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "```markdown", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard text.count >= 20 else { return nil }
        return text
    }

    public static func compose(
        note: MeetingNote,
        meeting: Meeting?,
        userPrompt: String,
        model: any LocalLanguageModel
    ) async throws -> String? {
        guard isUsable(prompt: userPrompt) else { return nil }
        let prompt = buildPrompt(note: note, meeting: meeting, userPrompt: userPrompt)
        let output = try await model.generate(
            systemPrompt: prompt.system,
            prompt: prompt.user,
            mode: .nonThinking,
            maxTokens: 2048
        )
        return clean(output)
    }
}
