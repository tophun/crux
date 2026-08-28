import Foundation

/// 프롬프트 모음. 모든 프롬프트는 한국어 회의를 전제하며 JSON만 출력하도록 요구한다.
public enum PromptLibrary {
    /// 모든 단계에 공통으로 적용되는 규칙. 원문에 없는 사실 생성을 금지한다(§8, §17).
    public static let systemPrompt = """
    당신은 한국어 회의 전사문을 정리하는 회의록 작성 도구다. 모든 처리는 이 기기 안에서만 이루어진다.

    반드시 지킬 규칙:
    1. 전사문에 없는 사실을 만들지 않는다. 추측으로 내용을 채우지 않는다.
    2. 결정사항과 제안사항을 구분한다. 확정되지 않은 것은 제안으로 표시한다.
    3. 담당자와 마감일은 전사문에서 직접 확인될 때만 채운다. 확인되지 않으면 null로 둔다.
    4. 모든 항목에는 근거가 되는 전사 구간 식별자(S로 시작하는 번호)와 원문 인용을 붙인다.
    5. 인용은 전사문에 있는 표현을 그대로 옮긴다. 문장을 새로 만들지 않는다.
    6. 출력은 JSON 하나만 낸다. 설명, 머리말, 코드펜스, 주석을 붙이지 않는다.
    """

    // MARK: - 1차 사실 추출 (비사고 모드)

    public static func windowExtraction(
        window: TranscriptWindow,
        meetingType: MeetingType = .general
    ) -> String {
        let emphasis = meetingType.extractionEmphasis.map { "\n\n\($0)\n" } ?? "\n"
        return """
        아래는 회의 전사문의 한 구간이다.

        \(window.promptTranscript())

        이 구간에서 다음을 추출하라.\(emphasis)
        - topics: 이 구간에서 다룬 주제
        - decisions: 결정 또는 제안된 사항. kind는 확정된 결정이면 "decided", 아직 제안·검토 단계면 "proposed"
        - actionItems: 누군가 하기로 한 일. 명시적 요청이나 충분한 근거가 있을 때만 만든다.
          dueDate는 전사문에 실제 날짜가 나온 경우에만 그 날짜를 쓴다. "다음 주 월요일"처럼 상대적 표현은
          dueDate를 null로 두고 dueDateNote에 그 표현을 그대로 넣는다. 날짜를 계산해서 채우지 않는다
        - risks: 리스크, 이슈, 장애 요인
        - openQuestions: 회의에서 답이 나오지 않은 질문
        - segmentRelevance: 각 전사 구간을 회의록에 어떻게 반영할지 분류

        segmentRelevance의 label 기준:
        - "KEEP": 결정, 액션, 담당자, 마감일, 일정 변경, 리스크, 미해결 질문, 수치, 결정 배경처럼 회의록에 필요한 내용
        - "CONDENSE": 사담과 업무 맥락이 섞여 핵심 의미만 남겨야 하는 내용
        - "EXCLUDE": 인사, 안부, 날씨, 교통, 식사, 개인사, 업무와 무관한 농담, 단순 맞장구, 회의 전후 대기성 대화
        - "UNCERTAIN": 중요한지 판단하기 어려운 내용

        판정 질문: 이 발언을 지웠을 때 회의에 참석하지 않은 사람이 결정·액션·배경·리스크를 정확히 이해할 수 있는가.
        이해에 지장이 있으면 KEEP 또는 CONDENSE로 둔다.

        애매한 항목은 ambiguity 배열에 이유를 한국어로 적는다.
        confidence는 0과 1 사이 숫자다.

        출력 형식(JSON만):
        {
          "topics": [{"title": "", "summary": ""}],
          "decisions": [{"content": "", "kind": "decided", "confidence": 0.0, "ambiguity": [], "evidence": [{"segment": "S0", "quote": ""}]}],
          "actionItems": [{"task": "", "assignee": null, "dueDate": null, "dueDateNote": null,
            "confidence": 0.0, "ambiguity": [], "evidence": [{"segment": "S0", "quote": ""}]}],
          "risks": [{"content": "", "severity": "unknown", "confidence": 0.0, "evidence": [{"segment": "S0", "quote": ""}]}],
          "openQuestions": [{"question": "", "confidence": 0.0, "evidence": [{"segment": "S0", "quote": ""}]}],
          "segmentRelevance": [{"segment": "S0", "label": "KEEP"}]
        }
        """
    }

    // MARK: - 사고 모드 재검토

    public static func factReview(
        fact: MeetingFact,
        window: TranscriptWindow,
        signals: [RoutingSignal],
        relatedFacts: [MeetingFact]
    ) -> String {
        let signalText = signals.map { "- \($0.explanation)" }.joined(separator: "\n")
        let related = relatedFacts.isEmpty
            ? "없음"
            : relatedFacts.enumerated().map { index, fact in
                "\(index + 1). [\(fact.kind.rawValue)] \(fact.content)"
                    + (fact.assignee.map { " / 담당: \($0)" } ?? "")
                    + (fact.dueDate.map { " / 마감: \($0)" } ?? "")
            }.joined(separator: "\n")

        return """
        아래 후보 항목이 회의록에 들어갈 수 있는지 전사문을 근거로 다시 판단하라.

        전사문:
        \(window.promptTranscript())

        후보 항목:
        - 종류: \(fact.kind.rawValue)
        - 내용: \(fact.content)
        - 결정 상태: \(fact.decisionKind?.rawValue ?? "미지정")
        - 담당자: \(fact.assignee ?? "없음")
        - 마감일: \(fact.dueDate ?? "없음")
        - 모호한 일정 표현: \(fact.dueDateNote ?? "없음")
        - 기존 근거: \(fact.evidence.map { "\($0.quote)" }.joined(separator: " | "))

        재검토가 필요한 이유:
        \(signalText)

        같은 회의의 관련 후보:
        \(related)

        판단 규칙:
        0. 전사문이 이 항목을 뒷받침하는데 근거 구간만 잘못 지정된 경우에는 폐기하지 말고 올바른 구간으로 근거를 바로잡는다.
           전사문에 아예 없는 내용일 때만 "discard"로 한다.
        1. 전사문에서 직접 확인되지 않는 내용은 확정하지 않는다.
        2. 결정으로 확정하기에 근거가 부족하면 kind를 "proposed"로 낮춘다.
        3. 담당자와 마감일은 전사문에 명시된 경우에만 채운다. 아니면 null로 둔다.
        4. 마감일은 전사문에 나온 표현을 그대로 쓴다. 상대적 표현("다음 주 월요일")을 실제 날짜로 바꾸지 않는다.
           표현이 모호하면 dueDate는 null로 두고 dueDateNote에 원문 표현을 남긴다.
        5. 같은 내용이 여러 번 나왔다면 최종 결론만 남긴다.
        6. 근거는 전사문에 실제로 있는 문장만 인용한다.

        출력 형식(JSON만):
        {
          "verdict": "confirm",
          "content": "",
          "kind": "decided",
          "assignee": null,
          "dueDate": null,
          "dueDateNote": null,
          "severity": "unknown",
          "confidence": 0.0,
          "evidence": [{"segment": "S0", "quote": ""}]
        }

        verdict는 "confirm"(유지), "revise"(수정해서 유지), "discard"(폐기) 중 하나다.
        """
    }

    // MARK: - 최종 회의록 생성

    public static func finalNote(
        meetingTitleHint: String,
        catalog: FactCatalog,
        transcriptDigest: String,
        meetingType: MeetingType = .general,
        calendarContext: MeetingCalendarContext? = nil
    ) -> String {
        let emphasis = meetingType.finalNoteEmphasis.map { "\n        \($0)" } ?? ""
        let calendarText: String
        if let calendarContext {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ko_KR")
            formatter.dateFormat = "yyyy년 M월 d일 HH:mm"
            let attendees = calendarContext.attendees.isEmpty
                ? "없음"
                : calendarContext.attendees.joined(separator: ", ")
            let conference = calendarContext.conferenceURL?.absoluteString ?? "없음"
            calendarText = """
            캘린더 메타데이터(전사 근거가 아님):
            - 일정 제목: \(calendarContext.title)
            - 시작: \(formatter.string(from: calendarContext.startDate))
            - 종료: \(formatter.string(from: calendarContext.endDate))
            - 참석자: \(attendees)
            - 회의 링크: \(conference)
            """
        } else {
            calendarText = "캘린더 메타데이터 없음"
        }

        return """
        아래는 한 회의에서 검증된 후보 항목들과 회의록에 남길 전사 요약이다.
        이것만 사용해 최종 회의록을 작성하라. 새로운 사실을 추가하지 않는다.

        회의 제목 힌트: \(meetingTitleHint)

        \(calendarText)

        캘린더 메타데이터는 제목·시간·참석자 표기를 보조할 뿐이다.
        결정사항·액션아이템·리스크·질문은 반드시 아래 검증된 후보와 전사 요약에만 근거한다.

        결정/제안 후보:
        \(catalog.describe(.decision))

        액션아이템 후보:
        \(catalog.describe(.actionItem))

        리스크 후보:
        \(catalog.describe(.risk))

        미해결 질문 후보:
        \(catalog.describe(.openQuestion))

        주제 후보:
        \(catalog.describe(.topic))

        회의록에 남길 전사 요약(사담은 이미 제외됨):
        \(transcriptDigest)

        작성 규칙:
        1. summary는 회의에 참석하지 않은 사람이 읽고 무엇이 결정됐는지, 누가 무엇을 언제까지 하는지, 무엇이 미결인지 알 수 있게 5문장 이내로 쓴다.
        2. 인사, 날씨, 식사, 개인사, 잡담은 넣지 않는다. "사담 제외" 같은 표현도 쓰지 않는다.
        2-1. 이 작성 규칙 자체를 회의록에 쓰지 않는다. "담당자는 확인된 항목만 기재합니다"처럼 지침을 설명하는
             문장은 요약에 넣지 않는다. 회의에서 실제로 나온 내용만 쓴다.
        2-2. 같은 항목을 결정사항과 액션아이템에 동시에 넣지 않는다. 누가 무엇을 하기로 한 일은 액션아이템에만 쓰고,
             결정사항에는 회의가 확정한 판단만 쓴다.
        3. 같은 내용을 반복해서 쓰지 않는다.
        4. 담당자와 마감일이 확인되지 않은 항목은 null로 둔다. 임의로 채우지 않는다.
        5. 각 항목의 evidenceIndex에는 위 후보 목록의 번호를 그대로 적는다. 근거를 새로 만들지 않는다.
        6. 후보 목록에 없는 항목은 만들지 않는다.
        7. title은 회의 내용을 나타내는 짧은 한국어 제목으로 쓴다.\(emphasis)

        출력 형식(JSON만):
        {
          "title": "",
          "summary": "",
          "decisions": [{"content": "", "kind": "decided", "evidenceIndex": 1}],
          "actionItems": [{"task": "", "assignee": null, "dueDate": null, "status": "proposed", "evidenceIndex": 1}],
          "openQuestions": [{"question": "", "evidenceIndex": 1}],
          "risks": [{"content": "", "severity": "unknown", "evidenceIndex": 1}],
          "topics": [{"title": "", "summary": ""}]
        }
        """
    }

    // MARK: - JSON 복구

    public static func repairJSON(raw: String, expectedShape: String) -> String {
        """
        아래 텍스트는 JSON이어야 하지만 형식이 잘못됐다. 내용을 바꾸지 말고 형식만 고쳐서 올바른 JSON 하나만 출력하라.
        값을 새로 만들지 않는다. 알 수 없는 값은 null로 둔다.

        기대 형식:
        \(expectedShape)

        잘못된 텍스트:
        \(raw.prefix(4000))
        """
    }
}
