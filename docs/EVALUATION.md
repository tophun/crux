# 품질 평가 (§16)

## 상태

**이번 세션에서는 실제 회의 20건 평가를 수행하지 않았다.** 평가 데이터셋이 없다.
아래는 측정 항목과 절차, 그리고 이미 코드에 들어 있는 계측 지점을 정리한 것이다.

## 코드가 이미 남기는 값

`MeetingNote.generation` (`GenerationSummary`)이 회의마다 저장된다.

| 필드 | 의미 |
| --- | --- |
| `windowCount` | 5~10분 창 개수 |
| `candidateCount` | 1차 추출 후보 수 |
| `thinkingReviewCount` | 사고 모드로 재검토한 항목 수 |
| `droppedCandidateCount` | 재검토에서 폐기된 후보 수 |
| `mergedDuplicateCount` | 반복 발언 통합 건수 |
| `evidenceRejectedCount` | 원문 불일치로 제거된 근거 수 (환각 지표) |
| `keptSegmentCount` / `condensedSegmentCount` / `excludedSegmentCount` / `uncertainSegmentCount` | 사담 분류 분포 |
| `finalPassUsedThinking` | 최종 종합에 사고 모드를 썼는지 |
| `jsonRepairCount` | JSON 복구 재요청 횟수 (출력 안정성 지표) |

`StageMetricsRecorder`가 단계별 소요 시간과 프로세스 RSS·최대 RSS를 남긴다
(`meetingctl run --verbose`가 그대로 출력한다).

## 측정 항목과 방법

| 지표 | 산출 방법 |
| --- | --- |
| 전사 정확도 | 회의별 정답 전사문 대비 CER/WER. 한국어는 CER을 주지표로 본다 |
| 결정사항 누락률 | 사람이 만든 정답 결정 목록 대비 회의록에 없는 항목 비율 |
| 액션아이템 누락률 | 같은 방식 |
| 잘못 생성된 액션아이템 비율 | 회의록의 액션 중 정답에 없거나 원문 근거가 없는 항목 비율 |
| 담당자 오인식률 | 담당자가 채워진 액션 중 정답과 다른 비율. `null`은 오인식이 아니라 미확정으로 따로 집계 |
| 마감일 오인식률 | 같은 방식 |
| 사담 포함률 | 회의록 문장 중 정답 기준 사담으로 분류된 문장 비율 |
| 중요한 맥락 삭제율 | 정답에서 중요로 표시한 구간 중 `EXCLUDE`로 판정된 비율 |
| 결과 생성 시간 | `StageMetric.duration` 합 |
| 최대 메모리 | `StageMetric.peakResidentBytes` 최댓값 |
| 처리 실패율 | `processingJob.state == failed` 회의 비율 |

**최우선 두 지표**

1. 사담이 충분히 제거되었는가 → 사담 포함률
2. 중요한 결정·리스크·액션을 삭제하지 않았는가 → 중요한 맥락 삭제율, 결정·액션 누락률

두 지표는 서로 상충한다. 현재 정책은 **중요 맥락 보존을 우선**한다
(강한 업무 신호가 있으면 모델이 `EXCLUDE`라 해도 `CONDENSE`로 올린다). 평가 후 이 균형을 조정한다.

## 절차

1. 회의 20건의 오디오와 정답 세트(전사문, 결정, 액션+담당자+마감일, 리스크, 미해결 질문, 구간별 중요도)를
   준비한다. 개인정보 포함 가능성이 있으므로 로컬에만 둔다.
2. `meetingctl run --audio <file> --db <평가용 DB> --out <출력 디렉터리> --verbose`를 회의마다 실행한다.
3. 회의록 JSON과 정답을 비교하는 채점 스크립트를 만든다(현재 미작성).
4. 지표를 표로 정리하고, 회의별 `GenerationSummary`를 함께 기록한다.
5. `evidenceRejectedCount`가 큰 회의는 프롬프트나 근거 검증 임계를 조정할 후보로 본다.

## 회귀 방지

정책을 바꿀 때는 다음 테스트가 먼저 깨져야 한다.

- 사담 분류: `RelevancePolicyTests`
- 사고 모드 라우팅: `ReasoningRouterTests`
- 근거 검증: `EvidenceValidatorTests`
- 반복 발언 통합: `FactDeduplicatorTests`
- 결정과 제안 구분: `FinalNoteParserTests`, `FactReviewParserTests`
- 회의록 생성 전체: `LocalInferencePipelineTests`

정책 변경 시 이 테스트를 함께 갱신하고, 평가 지표 변화를 기록한다.
