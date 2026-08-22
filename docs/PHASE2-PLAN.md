# 캘린더 · Atlassian · Live Capsule · Preview Viewer 설계와 검증

추가 요구사항 1~7의 설계 결정, 구현 위치, 검증 상태를 정리한다.

## 결정 사항 (사용자 승인)

| 항목 | 선택 | 이유 |
| --- | --- | --- |
| 캘린더 소스 | **EventKit** (macOS 캘린더에 구독된 Google 계정) | 네트워크·OAuth·GCP 프로젝트가 필요 없어 온디바이스 원칙을 지킨다. `CalendarProvider` 프로토콜을 두어 Google Calendar API 구현을 나중에 추가할 수 있다 |
| Atlassian 인증 | **API 토큰(Basic)** + Keychain | 개인·팀 단위 사용에 가장 단순하다. 토큰은 stdin으로만 받고 로그·인자에 남기지 않는다 |
| 게시 검증 | 샌드박스에 실제 게시 | 페이로드 단위 테스트만으로는 API 계약(spaceId·ADF·remote link)을 확인할 수 없다 |

## 1. Google Calendar 연동

| 요구사항 | 구현 |
| --- | --- |
| 일정을 읽어 회의 전후 상태 감지 | `MeetingCalendar/EventKitCalendarProvider`, `MeetingCore/MeetingDetectionPolicy` |
| 제목·날짜·참석자·회의 링크를 회의록 메타데이터로 | `CalendarEvent` → `PublishBundleBuilder`가 제목·날짜·참석자를 캘린더 우선으로 사용 |
| 시작 직전 또는 회의 앱·오디오 활성 시 Live Capsule | `MeetingDetectionPolicy.decide` — 임박(5분 전), 시작(10분 이내), 미등록 회의(회의 앱 + 마이크 사용 중) |
| 기본은 자동 녹음이 아니라 사용자 확인 | 캡슐이 "…가 시작된 것 같습니다. 회의록을 시작할까요?"를 띄우고, `startMeeting()`은 사용자 동작에서만 호출된다 |
| 종일·취소·참석자 없는 일정 제외 | `eligibleEvents` (기본 참석자 2명 이상) |
| 중복 알림 금지 | `notifiedEvent` 테이블 + `LiveCapsuleMachine.dismissedEventIds` — 앱을 다시 켜도 유지 |
| 캘린더 메타데이터는 로컬 저장 | `calendarEvent` 테이블. 네트워크 전송 없음 |

회의 링크는 이벤트의 `url`, `location`, `notes`에서 Zoom·Meet·Teams·Webex 호스트를 찾아 뽑는다
(`ConferenceLinkExtractor`).

## 2. Atlassian 연동

### Confluence

- `POST /wiki/api/v2/pages` — **v2는 spaceKey가 아니라 숫자 spaceId를 요구**하므로
  `GET /wiki/api/v2/spaces?keys=KEY`로 먼저 조회한다.
- 본문은 storage format(HTML). 문서 순서는 요구사항 그대로:
  회의 제목 → 날짜 → 참석자 → 회의 요약 → 주요 결정사항 → 액션 아이템 → 논의 내용 → 리스크 및 미해결 질문.
  날짜와 참석자를 문서 상단에 가장 먼저 노출한다(테스트로 순서를 고정).
- "논의 내용"은 **주제 요약 + 확정되지 않은 제안**으로 만든다. 전사 원문을 넣지 않는다.
- Jira 이슈를 만든 뒤 `PUT /wiki/api/v2/pages/{id}`로 이슈 키를 덧붙인다(버전 번호 증가 필요).

### Jira

- `POST /rest/api/3/issue` — `description`은 **ADF JSON**이다(plain text 아님).
- 기본 이슈 유형은 Task이고 Bug·Story를 선택할 수 있다. 우선순위도 선택 가능하다.
- `duedate`는 `YYYY-MM-DD`만 받는다. `KoreanDateParser`가 "3월 12일"처럼 해석 가능한 표현만 날짜로 바꾸고,
  "다음 주 월요일" 같은 상대 표현은 **날짜를 만들지 않고** 이슈 본문에 원문 표현을 남긴다.
- 담당자는 `GET /rest/api/3/user/search`로 accountId를 찾는다. 못 찾으면 비워 두고 사용자에게 알린다.
- `POST /rest/api/3/issue/{key}/remotelink`로 회의록 페이지를 연결한다.

### 전송 제한

- 전체 녹취록·음성 파일은 게시 타입(`ConfluencePageDraft`, `JiraIssueDraft`)에 **필드가 없다.**
- 승인(`approved`)이 없으면 `PublishError.notApproved`로 거부한다.
- 전송 직전 `MeetingPublisher.audit`이 검열 게이트를 실행한다.
- API 호출은 앱(`MeetingPublishing`)이 실행한다. 모델은 호출 경로를 갖지 않는다.

## 3. Live Capsule

`LiveCapsuleState` 상태 머신(순수)과 `LiveCapsuleWindowController`(AppKit)로 분리했다.

| 요구사항 | 구현 |
| --- | --- |
| 상태 흐름 | `hidden → imminent → detected → recording → generating → previewReady → published` (+ `failed`) |
| 표시 문구 | "회의가 시작된 것 같습니다", "녹음 중 · 12:34", "회의록 작성 중", "회의록 준비 완료", "Confluence 게시 · Jira 이슈 3개 생성" |
| 작고 간결한 캡슐 + 클릭 확장 | `LiveCapsuleView` — 기본 한 줄, 탭하면 상세 패널 |
| 포커스 비탈취 | `NSPanel(styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView])`, `level = .statusBar`, `canJoinAllSpaces` |
| 내장 화면 상단 중앙 / 외부 모니터는 활성 화면 | `LiveCapsuleWindowController.reposition()` — 마우스가 있는 화면의 `visibleFrame` 상단 중앙 |
| 녹음·일시정지·종료 상태 명확 표시 | 빨간 점(녹음) / 주황 점(일시정지), 경과 시간, 메뉴바에도 동일 상태 |
| 회의 종료 후 Preview로 전환 | `previewReady` 상태의 주 버튼이 검토 창을 연다 |

## 4. Preview Viewer

- 탭: 회의록 / Jira 액션 아이템 / 근거 확인
- 수정 가능: 회의록 문장, 결정사항, 액션 아이템, 담당자, 기한, Jira Project·이슈 유형·우선순위,
  Confluence Space, 생성 여부
- Preview와 게시가 같은 `PublishBundle`을 쓴다. 화면에서 고친 값이 그대로 전송된다.
- 게시 버튼은 (1) 사용자 승인 체크, (2) 차단 수준 품질 문제 없음일 때만 활성화된다.
- 근거 타임스탬프·원문은 "근거 확인" 탭에서만 보인다.

## 5·6. 한국어 윤문 Skill과 파이프라인

[docs/SKILLS.md](SKILLS.md) 참고. 요약하면

- `im-not-ai`(MIT)의 카테고리·심각도·처방·변경률 가드·내용 앵커 보존을 Swift 규칙으로 이식
- `fluent-korean`(MIT)의 조사·어미 생략 보정, 명사 나열 개선, 엠대시 자제를 K 카테고리로 편입
- 처리 경로(보수적·일반·정밀)는 탐지 밀도로 앱이 결정한다
- 근거 인용문·담당자·기한은 윤문 입력에서 제외한다(테스트로 고정)
- 7개 Skill의 실행 기록을 `MeetingSkillTrace`로 남긴다

## 7. 타임스탬프 정책

| 위치 | 타임스탬프 |
| --- | --- |
| `{meetingId}.evidence.json` | 있음 (로컬 전용) |
| Preview Viewer 근거 확인 탭 | 있음 |
| Confluence 페이지 | 없음 |
| Jira 이슈 | 없음 |
| 로컬 Markdown 내보내기 | 있음 (사용자 파일) |

연결은 내부 `contentId`(`D1`, `A2`, `R1`, `Q1`)로 한다. contentId 자체도 게시물에 넣지 않고,
게시 결과와의 연결은 로컬 `publishRecord` 테이블에만 둔다.

## 검증 상태

### 자동 테스트 (모델·네트워크 없이)

```
$ swift build && swift test
✔ Test run with 161 tests in 35 suites passed
```

새로 추가한 범위

| 영역 | 테스트 |
| --- | --- |
| 회의 감지 정책 | 종일·취소·참석자 부족 제외, 임박·시작·미등록 판정, 중복 알림 방지, 확인 문구 |
| Live Capsule | 전체 상태 흐름, 닫은 회의 재알림 금지, 녹음 중 감지 무시, 표시 문구 |
| 한국어 윤문 | 번역투 치환, 서식 정리, 관용구 제거, 보호 용어, 임계 탐지, 앵커 손실·과도 변경 롤백, 근거·담당자·기한 불변, 경로 선택 |
| 근거 분리 | contentId 부여, 파일 왕복, 파일명 |
| 기한 해석 | ISO·월일·롤포워드, 상대 표현 거부 |
| 게시 초안 | 캘린더 우선, 참석자 미추가, 제안/결정 분리, 미확정 표기, ADF 구조, 문서 순서, HTML 이스케이프 |
| 검열 게이트 | 정상 통과, 인용·타임스탬프·UUID·내부 키 차단 |
| 품질 검증 | 차단·경고 구분 |
| 게시 게이트 | 승인 없으면 거부, 근거 섞이면 거부, dry run 내용 |
| 인증 | 토큰 미노출, Basic 헤더, 환경 변수 |
| 오디오 합성 | 두 트랙 믹싱(실제 AVFoundation), 단일 트랙 복사, 입력 없음 오류 |
| 동시 처리 차단 | 처리 중 다른 회의 요청 거부, 끝난 뒤 재개, 모델 동시 상주 없음 |

### 실행에서 발견해 고친 결함

**검열 게이트가 정상 회의록을 막았다.** 실제 회의록으로 `preview`를 돌리자
"게시 금지 항목 포함(evidenceQuote): 가격 정책은 아직 정해지지 않았습니다."로 게시가 차단됐다.
원인은 모델이 발언을 그대로 옮겨 **회의록 항목 본문과 근거 인용문이 같은 문장**이 된 경우였다.
한국어 회의록에서는 흔한 상황이라 그대로 두면 기능을 쓸 수 없다.

수정: 근거 인용문이 **사용자가 검토·승인한 항목 본문에 이미 포함**되어 있으면 위반으로 보지 않는다.
항목 본문을 넘어서는 전사 문장(예: 한 세그먼트에 여러 문장이 있고 그중 일부만 회의록에 들어간 경우)은
계속 차단한다. 두 경우를 각각 테스트로 고정했다.

### 실측

| 항목 | 결과 |
| --- | --- |
| `swift build` | 성공 |
| `xcodebuild -scheme MeetingApp` | 성공 |
| `xcodebuild -scheme meetingctl` | 성공 |
| `Scripts/make_app.sh` | 성공. ad-hoc 서명, 번들 식별자 `local.meetingnotes.app`, 권한 사용 설명 3종 포함 |
| 앱 번들 실행 | 프로세스 정상 유지, 오류 로그 없음 |
| CLI `calendar` | 번들이 아니므로 캘린더 권한 거부 — 그 사실을 사용자에게 알리고 종료(설계 의도대로 동작) |
| CLI `preview` (실제 회의록) | 성공. Confluence 본문 순서(날짜·참석자 우선), Jira 초안 2건, 근거는 로컬 목록에만 표시, 게시 본문에 타임스탬프 0건 |
| 네트워크 감사 | `MeetingPublishing` 1개 파일만 HTTP 사용, 나머지 10개 모듈 0건, 토큰 로깅 0건 |

### 검증하지 못한 것

- **실기기 권한 흐름**: 마이크·캘린더·화면 기록 권한은 사람이 승인 창을 눌러야 한다. 승인 후의 실제 녹음,
  일정 읽기, 시스템 오디오 캡처는 측정하지 못했다.
- **Live Capsule 육안 렌더링**: 화면 기록 권한이 없어 `screencapture`가 검은 화면만 반환한다.
- **Atlassian 라이브 게시**: 아래 "라이브 검증 절차"를 사용자가 실행하면 확인된다.

## 라이브 검증 절차 (Atlassian)

```sh
M=.xcbuild/Build/Products/Debug/meetingctl

# 1) 토큰 등록 — 토큰은 stdin으로만 입력된다 (인자·로그에 남지 않는다)
$M auth --site your-team.atlassian.net --email you@example.com
#   → 프롬프트에 API 토큰 붙여넣고 Enter

# 2) 연결 확인
$M auth --verify

# 3) 게시할 내용 확인 (전송 없음)
$M preview --meeting <회의 UUID> --space <테스트 SPACE> --project <테스트 PROJECT>

# 4) 실제 게시
$M publish --meeting <회의 UUID> --space <테스트 SPACE> --project <테스트 PROJECT> --yes
```

API 토큰은 https://id.atlassian.com/manage-profile/security/api-tokens 에서 만든다.
게시된 테스트 페이지와 이슈는 확인 후 직접 삭제해야 한다.
