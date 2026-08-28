# 설계

## 모듈 구조

```
SwiftUI/AppKit UI            MeetingUI, MeetingApp
        ↓
MeetingController            AppState, MeetingProcessingPipeline
        ↓
AudioCaptureService          MeetingAudio (Phase 2에서 구현)
        ↓
AudioProcessingPipeline      MeetingAudio (AudioFileInspector, MeetingStorage)
        ↓
LocalInferencePipeline       MeetingCore.LocalInferencePipeline + MeetingTranscription/MeetingInference
        ↓
MeetingRepository            MeetingPersistence
        ↓
SwiftData + Local Files
```

모듈 이름에 제품명을 넣지 않았다. 제품명이 확정되면 `AppIdentity.productName`만 바꾸면 된다.

| 모듈 | 의존성 | 책임 |
| --- | --- | --- |
| `MeetingCore` | 없음 | 도메인 모델, 추론 정책(청킹·라우팅·사담 분류·근거 검증·중복 통합·프롬프트·파서), 내보내기 |
| `MeetingPersistence` | SwiftData | `@Model` 스키마, 기존 SQLite 마이그레이션, 회의/전사/회의록/작업 저장소 |
| `MeetingAudio` | AVFoundation, ScreenCaptureKit, CoreAudio | 마이크·시스템 오디오 캡처, 트랙 믹싱, 파일 검사, 회의별 파일 배치 |
| `MeetingCalendar` | EventKit, AppKit, CoreAudio | 캘린더 일정 읽기, 회의 앱·마이크 사용 감지 |
| `MeetingPublishing` | Foundation (URLSession) | Atlassian 게시와 Slack 액션 전송. **앱에서 유일하게 외부로 HTTP를 보내는 모듈** |
| `MeetingTranscription` | WhisperKit | `TranscriptionEngine` 구현 |
| `MeetingInference` | MLX Swift, swift-transformers | `LocalLanguageModel` 구현 |
| `MeetingPipeline` | Core/Persistence/Audio/Publishing | 단계 실행, 작업 기록, 모델 수명 관리, 가져오기, 근거 파일, 게시 준비 |
| `MeetingUI` | Core/Pipeline/Persistence/Publishing/Calendar/Audio | 목록·상세·편집·메뉴바·설정·Crux·Preview Viewer·세션 조정 |
| `MeetingApp`, `MeetingCLI` | 전부 | 조립 지점 |

**핵심 설계 결정: 무거운 엔진을 프로토콜 뒤로 격리했다.**
`MeetingCore`는 WhisperKit도 MLX도 모른다. 덕분에

- 추론 정책 전체를 모델 없이 테스트할 수 있고(83개 테스트가 4GB 모델 없이 0.1초에 돈다),
- MLX Swift 통합이 막히면 `LocalLanguageModel`을 구현한 로컬 worker로 교체할 수 있다(스펙 §7 대체안).

## 도메인 모델

| 타입 | 설명 |
| --- | --- |
| `Meeting` | 회의 한 건. 상태(`recording`…`completed`/`failed`), 저장 디렉터리, 출처 |
| `AudioTrack` | 마이크/시스템/mixed 트랙의 파일 경로와 메타데이터. **오디오 바이트는 DB에 넣지 않는다** |
| `AudioSegment` | 긴 오디오의 처리 단위 |
| `TranscriptSegment` | 전사 구간. 시작·종료 시각, 화자(미사용), 텍스트, 0…1 신뢰도. 프롬프트에서는 `S12` 형태의 짧은 식별자를 쓴다 |
| `Evidence` | 근거. 세그먼트 ID + 시각 + 원문 인용 |
| `MeetingFact` | 1차 추출 후보. 종류(결정/액션/리스크/질문/주제), 담당자, 마감일, 모호성 메모, 재검토·폐기 여부 |
| `RelevanceDecision` | 구간별 `KEEP`/`CONDENSE`/`EXCLUDE`/`UNCERTAIN` 판정과 이유 |
| `Decision`, `ActionItem`, `OpenQuestion`, `RiskItem`, `Topic` | 최종 회의록 항목 |
| `MeetingNote` | 회의록 + `GenerationSummary`(처리 관측값) |
| `ProcessingJob` | 단계별 작업 기록. 재처리 판단 근거 |

### 결정과 제안을 분리한다

`Decision.kind`가 `decided`/`proposed`를 구분한다. 근거가 없는 결정은 파서와 파이프라인 두 곳에서
자동으로 `proposed`로 낮춰진다. 회의록 Markdown에서도 "결정사항"과 "제안·검토 중"을 다른 절로 쓴다.

### 근거 없는 값은 `null`로 남긴다

`ActionItem.assignee`/`dueDate`는 원문에서 확인되지 않으면 `nil`이다. 모호한 일정 표현은
`dueDateNote`에 원문 그대로 보존하고 UI에는 `추가 확인 필요`로 표시한다.

## 회의 감지 → 게시 흐름 (추가 요구사항)

```
EventKit 일정 + 회의 앱·마이크 사용 감지
  → MeetingDetectionPolicy          종일·취소·참석자 필터, 중복 알림 방지
  → CruxMachine              캡슐 상태 (사용자 확인 대기)
  → MeetingAudioCapture             마이크 + 시스템 오디오, 트랙 분리 저장 + mixed 생성
  → MeetingProcessingPipeline       전사 → 회의록 → 한국어 윤문 → 근거 파일 분리
  → PublishPreparation              PublishBundle + 품질 검증
  → Preview Viewer                  사용자 검토·수정·승인
  → MeetingPublisher                검열 게이트 → Confluence 페이지 → Jira 이슈 → 상호 링크
  → SlackPublisher                  보내기 확인 + 검열 게이트 → 승인한 액션만 채널/DM
  → PublishRecord                   contentId ↔ 외부 식별자 (로컬 전용)
```

## 추론 흐름 (§8)

```
전사문
  → TranscriptChunker            5~10분 창 + 직전 2구간 맥락
  → 창별 1차 추출 (비사고 모드)   WindowExtractionParser
  → ReasoningRouter              규칙 기반 신호 평가
  → 신호가 하나 이상인 항목만 사고 모드 재검토
  → FactDeduplicator             반복 발언 통합, 담당자·마감일 변경 기록
  → EvidenceValidator            원문에 없는 인용 제거
  → 최종 종합 (복잡하면 사고 모드)
  → MeetingNote
```

### 라우팅 신호

스펙 §8의 전환 조건을 `RoutingSignal`로 1:1 대응시켰다.
`decisionAmbiguous`, `assigneeMissing`, `dueDateVague`, `multiSegmentEvidence`, `conflictingStatements`,
`crossWindowComparison`, `lowTranscriptConfidence`, `vagueExpression`, `multipleCandidates`,
`duplicateOrConflictingActions`, `missingEvidence`.

**신호가 하나라도 있으면 사고 모드로 간다**(스펙: "다음 조건 중 하나 이상"). 가중치 점수는 재검토 예산
(`maxThinkingReviews`, 기본 24건)이 부족할 때 우선순위를 정하는 데만 쓴다. 최종 종합 단계는 재검토 비율·
충돌 수·미확정 수를 보고 모드를 정하므로, 단순한 회의는 비사고 모드로 끝난다.

`ReasoningMode`는 UI에 노출하지 않고 사용자 설정도 없다.

### 근거 위조를 구조적으로 막는 두 장치

1. **짧은 식별자 + 인용 검증.** 모델은 `{"segment": "S12", "quote": "..."}`만 만든다. 타임스탬프는 앱이
   실제 세그먼트에서 채운다. 인용이 원문에 없으면 근거를 버리고, 다른 구간에 있으면 그 구간으로 교정한다.
2. **최종 단계는 번호만 참조한다.** `FactCatalog`가 후보에 1부터 번호를 붙이고, 모델은 `evidenceIndex`로만
   가리킨다. 프롬프트와 파서가 같은 카탈로그를 쓰므로 근거를 새로 만들 수 없다. 카탈로그에 없는 담당자·
   마감일 값은 무시하고 로그에 남긴다.

### JSON 신뢰성 (§10)

`JSONExtractor` → `JSONValue` 두 층으로 처리한다.

- 추출: 사고 블록 제거 → 코드펜스 제거 → 문자열·이스케이프를 인식하는 괄호 균형 스캔 → 스마트 쿼트·
  trailing comma·`//` 주석 정리 → 잘린 JSON 닫기.
- 접근: 키 표기 차이(snake/camel/한글), 숫자를 문자열로 준 경우(`"85%"`), `"null"`·`"미정"` 같은 결측 표현,
  단일 객체를 배열 자리에 준 경우를 흡수한다.
- 그래도 실패하면 비사고 모드로 **형식만 고치는 복구 요청**을 1회 보낸다. 최종 실패 시 해당 창만 건너뛰고
  규칙 판정으로 사담 분류를 채운다. 최종 종합이 실패하면 검증된 후보만으로 회의록을 만든다.
  어느 경우든 원본 오디오·전사문은 남으므로 재처리할 수 있다.

## 사담 제거 (§9)

모델 판정과 규칙 판정을 합치되 **보존 쪽으로 기울인다.**

- 강한 업무 신호(결정·일정·담당·리스크·비용·수치 등)가 있으면 모델이 `EXCLUDE`라 해도 `CONDENSE`로 올린다.
- 사담 신호만 있고 강한 업무 신호가 없으면 모델이 `KEEP`이라 해도 `EXCLUDE`로 내린다.
- 시간·수량 표현은 "약한 신호"로 따로 둔다. "다음 주 금요일에 회식"은 제외되고,
  "주말에 아이가 아파서 배포는 다음 주 수요일"은 `CONDENSE`로 업무 의미만 남는다.
- 사담 제거 대상은 **생성된 회의록**이다. 원본 오디오와 전체 전사문은 그대로 보존하고, 전사문 탭에서
  제외된 구간도 볼 수 있다. 회의록 본문에 "사담 제외" 같은 문구는 넣지 않는다.

## 메모리 (§12)

`ModelLifecycleCoordinator`(actor)가 두 엔진의 로드·해제를 독점한다.

```swift
try await coordinator.withTranscription { engine in ... }   // LLM이 올라와 있으면 먼저 내린다
try await coordinator.withLanguageModel { model in ... }    // 전사 모델이 올라와 있으면 먼저 내린다
await coordinator.releaseAll()
```

테스트가 두 모델의 동시 상주를 감시하고, 전사 모델 해제가 LLM 로드보다 먼저 일어나는지 순서까지 확인한다.
개발 장비 메모리가 넉넉해도 규칙이 깨지지 않는다.

`StageMetricsRecorder`가 단계별 소요 시간과 프로세스 RSS·최대 RSS를 기록한다.

## 저장소

SwiftData 모델: `MeetingModel`, `AudioTrackModel`, `TranscriptSegmentModel`, `NoteModel`, `DecisionModel`,
`ActionItemModel`, `OpenQuestionModel`, `RiskItemModel`, `TopicModel`, `ProcessingJobModel`,
`CalendarEventModel`, `NotifiedEventModel`, `PublishRecordModel`.

- 근거 배열과 생성 관측값은 기존 형식과 호환되는 JSON 문자열로 저장한다.
- 오디오 바이트는 저장하지 않고 파일 경로와 메타데이터만 저장한다.
- 회의 삭제 시 `MeetingRepository`가 연결 모델을 명시적으로 삭제한다.
- `processingJob`은 `(meetingId, stage)`가 유일하다. 앱 시작 시 `markRunningJobsInterrupted()`로
  실행 중이던 작업을 중단 상태로 바꿔 재처리 대상으로 만든다.
- 검색은 전사문·액션아이템·결정사항·회의록 제목/요약을 메모리에서 검색한다. 데이터 규모가 커지면
  SwiftData predicate 또는 별도 검색 인덱스를 도입한다.

### 기존 SQLite 마이그레이션

기존 `meetings.sqlite`는 삭제하거나 덮어쓰지 않고 옆의 `<이름>.swiftdata`로 가져온다. 전체 테이블을
읽기 전용 SQLite 연결로 읽어 임시 SwiftData 저장소에 먼저 저장하고, 모든 저장이 성공한 경우에만
최종 경로로 이동한다. 변환 중 오류가 나면 `ModelContext.rollback()`으로 현재 작업을 되돌리고
임시 저장소를 삭제한다. 원본 SQLite는 보존되므로 다음 실행에서 재시도하거나 복구용으로 사용할 수 있다.

## 재처리 (§17: 데이터 유실보다 재처리 우선)

- 각 단계가 시작·종료·시도 횟수·오류 메시지를 남긴다.
- 전사문이 이미 있으면 음성 인식을 건너뛴다. 앱이 죽은 뒤 재시작하면 LLM 단계만 다시 돈다.
- 손상된 오디오는 준비 단계에서 걸러 이후 단계를 낭비하지 않는다.
- `meetingctl retry` 또는 상세 화면의 "다시 처리" 버튼으로 재시도한다.
