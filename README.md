# Crux

> 제품명은 **Crux**로 확정했다. 화면 상단의 플로팅 캡슐 UI 이름이자 제품 이름이다.
> 코드에서는 `AppIdentity.productName`(표시 이름)과 `AppIdentity.bundleName`(파일·번들 이름)에서만 정의한다.

macOS 전용 **온디바이스 AI 회의록** 앱.

- 캘린더가 회의를 감지하고, **Crux**이 회의록 시작을 제안한다.
- 녹음·음성 인식·회의록 생성·한국어 윤문은 모두 이 기기에서 처리한다.
- **Preview Viewer**에서 사용자가 검토·수정하고 승인한 내용만 **Confluence**에 게시하고
  액션 아이템을 **Jira** 이슈로 만든다.
- 회의 오디오, 전체 전사문, 근거 타임스탬프는 외부로 전송하지 않는다.

> 제품명이 확정되지 않았으므로 문서에서는 `Crux`을 사용한다.
> 코드에는 제품명을 넣지 않았고, 사용자에게 보이는 이름은 `Sources/MeetingCore/Support/AppIdentity.swift`의
> `productName` 한 곳에서만 정의한다.

## 현재 구현 상태

| 범위 | 상태 |
| --- | --- |
| Phase 1 수직 슬라이스 (파일 → 전사 → 회의록 → 저장 → 표시) | 구현 완료 |
| 자동 사고 모드 라우팅 (§8) | 구현 완료 |
| 불필요한 사담 제거 (§9) | 구현 완료 |
| 근거 타임스탬프 연결·검증 (§10) | 구현 완료 |
| SQLite 저장, 회의록 수정, Markdown/JSON 내보내기, 재처리 | 구현 완료 |
| SwiftUI 회의 목록·상세·타임라인·메뉴바 | 구현 완료 |
| 마이크 녹음 (`AVAudioEngine`) + 시스템 오디오 (`ScreenCaptureKit`) + 트랙 분리·mixed 생성 | 구현 완료 (실기기 권한 검증 필요) |
| 캘린더 회의 감지 (EventKit) + 중복 알림 방지 | 구현 완료 (권한 승인 후 검증 필요) |
| Crux (상단 플로팅 캡슐, 포커스 비탈취) | 구현 완료 (육안 미검증) |
| Preview Viewer (회의록 / Jira 액션 아이템 / 근거 확인) | 구현 완료 |
| 한국어 윤문 Skill (`korean-meeting-editor`) | 구현 완료 |
| Confluence 게시 · Jira 이슈 생성 · 상호 링크 | 구현 완료 |
| 근거 분리 (`{meetingId}.evidence.json`) + 검열 게이트 | 구현 완료 |
| 화자 구분, 실시간 자막·요약 | MVP 제외 |

검증 결과는 [docs/PHASE1-PLAN.md](docs/PHASE1-PLAN.md)의 "검증 기록"에 실제 실행 로그 기준으로 적어 두었다.

## 요구 환경

- macOS 15 이상 (개발·검증은 macOS 26.5, Apple M4 Pro에서 수행)
- Xcode 26 이상, Swift 6.2
- **Metal Toolchain** — MLX Swift가 Metal 셰이더를 컴파일하는 데 필요하다.
  `swift build`(SwiftPM CLI)는 Metal 셰이더를 빌드하지 못하므로 **LLM을 쓰는 실행 파일은 `xcodebuild`로 빌드해야 한다.**
  ```sh
  xcodebuild -downloadComponent MetalToolchain   # 약 700MB, 1회
  ```
- 최초 실행 시 모델 다운로드용 네트워크 (그 이후는 오프라인 동작)

## 빌드

```sh
# 1) 라이브러리·테스트 (LLM 제외한 전 범위) — 빠르고 Metal 불필요
swift build
swift test          # 161개 테스트

# 2) 실제 모델을 쓰는 실행 파일 (Metal 셰이더 포함)
xcodebuild -scheme meetingctl -destination 'platform=OS X,arch=arm64' \
  -derivedDataPath .xcbuild -configuration Debug -skipMacroValidation build
xcodebuild -scheme MeetingApp -destination 'platform=OS X,arch=arm64' \
  -derivedDataPath .xcbuild -configuration Debug -skipMacroValidation build

# 3) 앱 번들 생성 (캘린더·마이크·화면 기록 권한은 번들에서만 받을 수 있다)
make app
open .xcbuild/Crux.app

# 산출물
.xcbuild/Build/Products/Debug/meetingctl
.xcbuild/Crux.app
```

`make_app.sh`는 Info.plist(권한 사용 설명), mlx Metal 셰이더(`Contents/MacOS/mlx.metallib`),
개인 Apple Development 코드 서명을 함께 넣는다. 키체인에 회사 팀 인증서가 있어도
이름에 이메일이 있는 개인 인증서를 고른다. 다른 인증서는 `CODESIGN_IDENTITY`로 지정한다.
번들 식별자는 기본 `local.crux.app`이며 Developer ID를 쓰게 되면 `BUNDLE_ID` 환경 변수로 바꾼다.

```sh
make dmg   # 서명된 Crux.app + Applications 바로가기가 들어 있는 DMG
```

`-skipMacroValidation`은 `mlx-swift-lm`의 매크로(`MLXHuggingFaceMacros`) 신뢰 확인을 건너뛰기 위한 것이다.
Xcode GUI에서는 첫 빌드 때 매크로 신뢰를 한 번 눌러주면 된다.

## 실행

### CLI (헤드리스 검증용)

```sh
M=.xcbuild/Build/Products/Debug/meetingctl

# 오디오 파일 하나를 끝까지 처리하고 회의록을 출력·내보내기
$M run --audio ~/Desktop/meeting.m4a --title "주간 회의" --out ~/Desktop/out --verbose

# 전사만
$M transcribe --audio ~/Desktop/meeting.m4a

# 저장된 전사문으로 회의록만 다시 생성 (LLM 단계만 검증)
$M note --meeting <회의-UUID>

# 오디오 보관 상태 확인 / 기간이 지난 오디오 정리 (전사문·회의록·근거는 유지)
$M retention
$M retention --policy days30 --sweep

# 목록 / 회의록 출력 / 재처리
$M list
$M show --meeting <회의-UUID> --format md
$M retry --meeting <회의-UUID>

# 완전 오프라인 검증 (모델 다운로드 금지)
$M run --audio meeting.m4a --offline --llm-directory ~/models/Qwen3-4B-4bit

# 인식 힌트 — 회의에서 자주 쓰는 고유명사·약어의 표기 정확도를 올린다
$M run --audio meeting.m4a --vocabulary "QA, 릴리즈, 스프린트, 온보딩, 결제 모듈"

# 캘린더 일정과 회의 감지 결과 확인 (EventKit, 네트워크 미사용)
$M calendar --hours 6

# 마이크(+시스템 오디오) 녹음 후 회의록 생성
$M record --seconds 60 --title "주간 회의"

# Atlassian 인증 정보 등록 — 토큰은 stdin으로만 입력하며 인자·로그에 남지 않는다
$M auth --site your-team.atlassian.net --email you@example.com
$M auth --verify

# 게시할 내용과 품질 검증 결과 확인 (전송하지 않음)
$M preview --meeting <UUID> --space TEAM --project PROJ

# 승인한 회의록 게시 + 액션 아이템을 Jira 이슈로 생성
$M publish --meeting <UUID> --space TEAM --project PROJ --yes
```

### 앱

```sh
open .xcbuild/Build/Products/Debug/MeetingApp
```

- 툴바 또는 메뉴바에서 **오디오 파일 가져오기**를 선택하면 가져오기 → 전사 → 회의록 생성이 이어서 실행된다.
- 메뉴바는 상태·진행률·마지막 회의록 열기·설정을 제공한다. 녹음 시작/정지는 Phase 2에서 활성화된다.
- 상세 화면 탭: 요약 / 결정사항 / 액션아이템 / 리스크 / 미해결 질문 / 전사문 / 타임라인.
- 액션아이템은 작업 내용·담당자·마감일·상태를 수정할 수 있고 근거 타임스탬프는 유지된다.

> 현재 `MeetingApp`은 SwiftPM 실행 파일이라 앱 번들(Info.plist)이 없다. 마이크·시스템 오디오 권한이 필요한
> Phase 2에서는 `.app` 번들과 `NSMicrophoneUsageDescription` 등의 사용 설명, 코드 서명이 필요하다.

## 모델

| 용도 | 기본 모델 | 저장 위치 |
| --- | --- | --- |
| 음성 인식 | WhisperKit `openai_whisper-large-v3-v20240930_turbo` (large-v3 turbo) | `~/Library/Application Support/Crux/models` |
| 회의록 생성 | `mlx-community/Qwen3-4B-4bit` (사고 모드 전환이 가능한 원본 Qwen3-4B) | `~/Library/Application Support/Crux/models/mlx` |

- 첫 실행 때 두 모델을 내려받는다(합계 약 4GB). 이후에는 네트워크 없이 동작한다.
- 메모리가 부족하면 음성 인식 모델을 `openai_whisper-large-v3-v20240930_626MB`로 낮출 수 있다
  (`--whisper-model`).
- 이미 내려받은 LLM 디렉터리를 `--llm-directory`로 지정하면 네트워크를 전혀 사용하지 않는다.
- `Qwen3-4B-Instruct-2507`이 아니라 원본 `Qwen3-4B`를 쓴다. 사고 모드 전환(`enable_thinking`)이 필요하다.

## 권한

앱 번들(`.xcbuild/Crux.app`)로 실행해야 권한을 받을 수 있다. CLI 실행 파일은 번들이 아니라
캘린더 권한을 받을 수 없다(실행 시 그 사실을 알려 준다).

| 권한 | 용도 | 요청 방법 |
| --- | --- | --- |
| 마이크 | 회의 녹음 | 첫 녹음 시 자동 요청 (`NSMicrophoneUsageDescription`) |
| 캘린더 | 회의 감지, 제목·날짜·참석자 | 설정 화면의 "캘린더 권한 요청" (`NSCalendarsFullAccessUsageDescription`) |
| 화면 및 시스템 오디오 기록 | 시스템 오디오(Zoom·Meet·Teams 소리) | 시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 기록에서 허용 |

시스템 오디오 권한이 없으면 **마이크만으로 녹음을 계속하고** 그 사실을 사용자에게 알린다.
설정 화면에 세 권한 상태와 데이터 저장 위치를 표시한다.

## Google Calendar 연동

`CalendarProvider` 프로토콜의 EventKit 구현을 쓴다. macOS 캘린더 앱에 Google 계정을 추가해 두면
Google Calendar 일정을 **네트워크 요청 없이** 읽는다.

- 회의 시작 5분 전부터 임박 상태, 시작 후 10분까지 "시작한 것 같다"로 본다.
- 종일 일정, 취소된 일정, 참석자 2명 미만 일정은 제외한다.
- 같은 회의에 두 번 묻지 않는다(알림 기록을 DB에 남겨 앱 재실행 후에도 유지).
- 캘린더에 없어도 회의 앱이 실행 중이고 마이크가 사용 중이면 확인을 요청한다.
- 자동 녹음하지 않는다. 캡슐에 "회의록을 시작할까요?"를 띄우고 사용자가 누를 때 시작한다.

## Atlassian 연동

| 대상 | 내용 |
| --- | --- |
| Confluence | 회의 제목 → 날짜 → 참석자 → 회의 요약 → 주요 결정사항 → 액션 아이템 → 논의 내용 → 리스크 및 미해결 질문 순서로 페이지 생성. 날짜·참석자를 문서 상단에 먼저 노출 |
| Jira | 액션 아이템을 선택한 프로젝트의 이슈로 생성(기본 Task, Bug·Story 선택 가능). 제목·상세·프로젝트·유형·담당자·기한·우선순위·생성 여부를 게시 전에 검토 |
| 상호 링크 | Jira 이슈에 회의록 페이지 링크(remote link), 회의록 페이지에 생성된 이슈 키 |

- 인증은 API 토큰(Basic)이며 Keychain에 저장한다. 토큰은 stdin으로만 입력받는다.
- **전체 녹취록과 음성 파일은 전송하지 않는다.** 게시 타입에 담을 필드가 없고, 전송 직전 검열 게이트가
  근거 인용·타임스탬프·내부 ID를 다시 확인한다.
- API 호출은 앱이 사용자 승인 후 실행한다. 모델이 직접 호출하지 않는다.

## Crux과 Preview Viewer

Crux은 화면 상단 중앙의 작은 플로팅 캡슐이다(`NSPanel`의 `.nonactivatingPanel` — 다른 앱의
포커스를 빼앗지 않는다). 외부 모니터를 쓰면 마우스가 있는 화면에 표시한다.

```
회의 임박 → 회의 시작 감지 → 녹음 중 · 12:34 → 회의록 작성 중
→ 회의록 준비 완료 → Confluence 게시 · Jira 이슈 3개 생성
```

클릭하면 상세 패널로 확장되고, 녹음·일시정지 상태를 명확히 표시한다.

Preview Viewer 탭: **회의록** / **Jira 액션 아이템** / **근거 확인**.
회의록 문장, 결정사항, 액션 아이템, 담당자, 기한, Jira Project·이슈 유형, Confluence Space, 생성 여부를
모두 여기서 수정한다. Preview와 실제 게시는 같은 구조화 데이터(`PublishBundle`)에서 렌더링된다.
근거 타임스탬프와 원문은 "근거 확인" 탭에서만 보이고 게시물에는 들어가지 않는다.

## 메모리 (16GB 제약)

- **음성 인식 모델과 LLM을 동시에 메모리에 올리지 않는다.** `ModelLifecycleCoordinator`가 로드·해제 순서를
  독점 관리하고, 테스트가 두 모델의 동시 상주를 금지한다.
- 전사가 끝나면 WhisperKit을 해제한 뒤 Qwen3를 로드한다.
- 긴 오디오는 WhisperKit `incremental` 로딩으로 스트리밍 처리하고, 전사문은 5~10분 창으로 나눠 LLM에 넣는다.
- MLX GPU 캐시 상한(기본 128MB)과 KV 캐시 상한(8192 토큰)을 두어 메모리 사용을 예측 가능하게 한다.
- 단계별 소요 시간과 프로세스 RSS·최대 RSS를 로그로 남긴다(`--verbose`, 앱 로그).

## 개인정보

- 회의 오디오는 파일 시스템에만 저장하고 SQLite에는 경로와 메타데이터만 넣는다.
- 회의록·전사문·액션아이템·캘린더 메타데이터는 로컬 SQLite에 저장한다.
- 근거 타임스탬프와 원문 인용은 `{meetingId}.evidence.json`에만 둔다.
- 모델의 내부 사고(`<think>...</think>`)는 노출하지 않고 저장하지 않는다.
- 외부로 나가는 통신은 **모델 다운로드**와 **사용자가 승인한 회의록·액션 아이템 게시**뿐이다.
  앱 코드에서 HTTP를 보내는 모듈은 `MeetingPublishing` 하나다(감사 결과는
  [docs/PRIVACY-NETWORK.md](docs/PRIVACY-NETWORK.md)).
- 원본 오디오 삭제와 회의록 내보내기(Markdown/JSON)는 상세 화면에서 할 수 있다.

## 알려진 제약

1. **SwiftPM CLI로는 LLM 실행 파일을 만들 수 없다.** MLX Metal 셰이더 때문에 `xcodebuild`와
   Metal Toolchain이 필요하다.
2. **권한은 앱 번들에서만 받을 수 있다.** CLI의 `calendar` 명령은 번들이 아니라 캘린더 권한을 받지 못한다
   (실행 시 그 사실을 알려 준다). 녹음·캘린더·시스템 오디오는 `Crux.app`으로 실행해야 한다.
3. **회의록 항목 중복.** 같은 내용이 결정사항과 액션아이템에 함께 나오는 경우가 있다.
4. **인식 힌트(`--vocabulary`) 부작용.** 프롬프트 토큰이 디코딩에 영향을 주어 구간이 거칠게 합쳐질 수 있다
   (검증에서 24구간 → 6구간). 기본값은 비활성이며, `TranscriptSegmenter`가 90자를 넘는 구간을 문장 단위로
   다시 나눠 영향을 줄인다.
5. **한국어 약어 표기 오류.** 검증에서 "QA팀"이 "카팀"으로 전사됐다. `--vocabulary`로 완화되지만
   완전히 없어지지는 않는다.
6. **화자 구분 없음.** `TranscriptSegment.speakerId`는 준비돼 있으나 채워지지 않는다.
7. **평가 데이터셋 없음.** §16 지표 산출을 위한 실제 회의 20건 평가는 수행하지 않았다
   ([docs/EVALUATION.md](docs/EVALUATION.md)).
8. **60분 회의 실측 미완.** 창 분할·메모리 경로는 단위 테스트로 검증했지만 실제 60분 오디오 처리는
   측정하지 않았다.
9. **실기기 권한 흐름 미검증.** 마이크·캘린더·화면 기록 권한 승인 후의 실제 녹음과 일정 읽기는
   사람이 권한을 눌러야 확인할 수 있어 이번 범위에서 측정하지 못했다.
10. **Preview 품질 경고가 편집 즉시 갱신되지 않는다.** 화면에서 문장을 고친 뒤 경고 목록이 바로 바뀌지 않을 수 있다.
    게시 직전 검열 게이트가 다시 검사하므로 잘못된 내용이 나가지는 않는다.
11. **한 번에 한 회의만 처리한다.** 처리 중 다른 회의를 요청하면 거부한다(모델을 동시에 두 개 올리지 않기 위함).
12. **Crux 육안 미검증.** 상태 머신은 테스트로 고정했지만 화면 렌더링은 화면 기록 권한이 없어
    캡처할 수 없었다.

## 저장소 구조

```
Package.swift
Sources/
  MeetingCore/          도메인 모델 + 추론 정책 + 윤문 Skill + 게시 초안 (외부 의존성 없음)
  MeetingPersistence/   SQLite (GRDB) 저장소
  MeetingAudio/         마이크·시스템 오디오 캡처, 믹싱, 파일 검사, 저장 배치
  MeetingCalendar/      EventKit 캘린더 읽기, 회의 앱·마이크 사용 감지
  MeetingTranscription/ WhisperKit 엔진
  MeetingInference/     MLX Swift + Qwen3 엔진
  MeetingPublishing/    Atlassian 게시 (앱에서 유일하게 외부로 HTTP를 보내는 모듈)
  MeetingPipeline/      단계 오케스트레이션, 모델 수명 관리, 근거 파일, 게시 준비
  MeetingUI/            SwiftUI 화면 + Crux + Preview Viewer
  MeetingApp/           앱 조립 지점 (메뉴바 + 창 + 캡슐 + 설정)
  MeetingCLI/           meetingctl 헤드리스 하네스
Makefile               make app / make dmg
scripts/make_app.sh    앱 번들 생성 (권한 사용 설명 + 개인 개발자 서명)
scripts/make_dmg.sh    서명된 앱을 DMG로 포장
Tests/                  161개 테스트 (모델 없이 실행)
Fixtures/               한국어 회의 음성 픽스처 생성 스크립트와 원본 텍스트
docs/                   설계·계획·Skill·개인정보·평가 문서
```

자세한 설계는 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), Skill 구성은 [docs/SKILLS.md](docs/SKILLS.md),
캘린더·Atlassian·Crux 설계와 검증 기록은 [docs/PHASE2-PLAN.md](docs/PHASE2-PLAN.md)를 참고한다.
