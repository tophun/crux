# Skill 구성 (요구사항 5·6)

## 작업별 Skill

Qwen의 단일 출력물을 그대로 쓰지 않는다. 단계마다 책임을 나누고 결과를 검증한다.

```
음성 인식
  → meeting-fact-extractor     구간별 사실 추출
  → meeting-cleaner            사담 제거
  → action-item-extractor      액션 아이템 확정, 담당자·기한 근거 검증
  → korean-meeting-editor      한국어 윤문
  → confluence-writer          Confluence 형식 변환
  → jira-task-writer           Jira 이슈 초안 변환
  → meeting-quality-checker    품질 검증
  → Preview Viewer             사용자 검토·수정
  → 사용자 승인
  → 게시
```

| Skill | 구현 위치 | 비고 |
| --- | --- | --- |
| `meeting-fact-extractor` | `MeetingCore/Reasoning/WindowExtractionParser.swift` + `LocalInferencePipeline` | 비사고 모드 1차 추출 |
| `meeting-cleaner` | `MeetingCore/Reasoning/RelevancePolicy.swift` | 규칙 + 모델 판정 병합, 보존 우선 |
| `action-item-extractor` | `LocalInferencePipeline` + `DueDateGrounding` + `FactReviewParser` | 담당자·기한 근거 검증 포함 |
| `korean-meeting-editor` | `MeetingCore/Skills/KoreanMeetingEditor.swift` | 아래 상세 |
| `confluence-writer` | `MeetingCore/Publishing/PublishBundleBuilder.swift` → `ConfluencePageDraft` | storage format 생성 |
| `jira-task-writer` | 같은 파일 → `JiraIssueDraft` | ADF description 생성 |
| `meeting-quality-checker` | `MeetingCore/Publishing/PublishBundleBuilder.swift` → `MeetingQualityChecker` | 차단/경고 구분 |

실행 기록은 `MeetingSkillTrace`로 남고 회의록의 `generation.skills`에 저장된다.
Preview Viewer와 로그에서 어떤 Skill이 몇 건을 처리했는지 볼 수 있다.

**설계 원칙**: 이미 검증된 파이프라인을 갈아엎지 않았다. 기존 단계에 이름을 붙이고,
실제 신규 단계(`korean-meeting-editor`, 두 writer, quality checker)만 추가했다.

## korean-meeting-editor

두 오픈소스 Skill의 지침을 앱 내부 규칙으로 재구성했다. Claude Plugin을 Qwen에 설치하는 방식이 아니라,
규칙과 처리 방식을 Swift 코드로 이식했다.

| 출처 | 라이선스 | 이식한 내용 |
| --- | --- | --- |
| [epoko77-ai/im-not-ai](https://github.com/epoko77-ai/im-not-ai) | MIT (Copyright (c) 2026 epoko77-ai) | `quick-rules.md` v2.0의 카테고리 체계(A~J), 규칙 ID, 심각도(S1/S2/S3), 처방, Do-NOT 목록, 변경률 가드(30% 경고 / 50% 롤백), 내용 앵커 보존, 처리 경로(보수적·일반·정밀) |
| [snflkd/fluent-korean](https://github.com/snflkd/fluent-korean) | MIT (Copyright (c) 2026 snflkd) | 조사·어미 생략 보정, 명사 나열 개선, 관형격 조사 남용 축소, 엠대시 자제 — K 카테고리로 편입 |

원본은 Claude Code용 플러그인·output style이므로 지침만 추출했다. 코드를 복사하지 않았다.

### 규칙 체계

| 카테고리 | 내용 | 구현된 규칙 |
| --- | --- | --- |
| A | 번역투 | A-1, A-3, A-7, A-8, A-9, A-10, A-11, A-16, A-19 |
| C | 기계적 구조 | C-5(이모지), C-9(숫자 인덱싱), C-11(연결어미 뒤 쉼표) |
| D | AI 관용구 | D-1(결산 관용구), D-2(의의 과장), D-3(열거 도입), D-4(hype) |
| G | 과도한 완곡 | G-1, G-2 |
| H | 접속사 남발 | H-1, H-3 |
| I | 형식명사 과다 | I-2, I-3, I-4 |
| J | 시각 장식 | J-1(볼드), J-3(엠대시) |
| K | 의미 명확성 (fluent-korean) | K-1(명사구 종결), K-2(조사 생략), K-3(관형격 중첩) |

규칙마다 **결정적 치환**이 있는 것과 **탐지만** 하는 것을 나눴다.

- 결정적 치환: 문법적으로 안전한 것만 (조사 선택은 종성 판별로 처리). LLM 없이 동작한다.
- 탐지만: 문맥 판단이 필요한 것. LLM에 해당 구간만 알려 주고 고치게 한다.

### 처리 경로 (앱이 자동 선택)

| 경로 | 조건 | 동작 |
| --- | --- | --- |
| 보수적 | 텍스트 120자 미만 또는 탐지 0건 또는 LLM 없음 | 규칙 치환만 |
| 일반 | 기본 | 규칙 치환 + LLM 국소 윤문 1회 |
| 정밀 | S1 3건 이상 또는 탐지 8건 이상 | 규칙 치환 + LLM 윤문 + 잔존 S1 재처리 |

사용자는 경로를 고르지 않는다.

### 안전 장치

1. **근거 인용문은 입력에 들어가지 않는다.** 윤문 대상은 회의록의 `title`, `summary`,
   `decisions[].content`, `actionItems[].task`, `openQuestions[].question`, `risks[].content`,
   `topics[].summary`뿐이다. `Evidence.quote`, 담당자, 기한, 상태는 손대지 않는다.
   인용문이 바뀌면 근거 검증(`EvidenceValidator`)이 무너지기 때문이다. 테스트로 고정했다.
2. **내용 앵커 보존.** 원문의 숫자, 영문 토큰, 큰따옴표 인용을 뽑아 결과에 남아 있는지 확인한다.
   하나라도 사라지면 그 필드를 롤백한다.
3. **변경률 가드.** 30% 초과는 경고, 50% 초과는 롤백. 문자 단위 편집 거리로 계산한다.
4. **길이 가드.** LLM 응답이 원문의 절반 미만이거나 두 배 초과면 지시를 벗어난 것으로 보고 버린다.
5. **보호 용어.** API·LLM·QA·prompt·token 같은 표준 기술 용어와 제품명이 든 구간은 건드리지 않는다.

### 검증

`Tests/MeatingCoreTests/KoreanEditorTests.swift`에서 다음을 고정했다.

- 번역투 결정적 치환 (4종)
- 연결어미 쉼표·볼드·엠대시 정리
- AI 관용구·이모지 제거
- 보호 용어 보존
- 임계 기반 탐지 (1회는 통과, 반복은 탐지)
- 내용 앵커 손실 시 롤백
- 변경률 초과 시 롤백
- 근거 인용문·담당자·기한 불변
- 처리 경로 자동 선택
