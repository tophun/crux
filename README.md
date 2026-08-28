# Crux

macOS용 온디바이스 AI 회의록 앱입니다.

- 오디오 파일을 가져오거나 마이크로 회의를 녹음합니다. 권한이 있으면 시스템 오디오도 함께 캡처합니다.
- WhisperKit으로 전사하고, 로컬 Qwen3 모델로 회의록을 작성합니다.
- 사담을 분류해 회의록 입력에서 제외하고, 결정사항·액션 아이템·리스크·미해결 질문에 근거 타임스탬프를 연결합니다.
- 회의록과 전사문을 로컬에 저장하고, 앱에서 내용을 수정·재생·내보내기할 수 있습니다.
- Preview Viewer에서 검토한 뒤 승인한 회의록만 Confluence에 게시하고 액션 아이템을 Jira 이슈로 만들 수 있습니다.

회의 오디오와 전사문은 외부로 보내지 않습니다. 외부 통신은 모델 다운로드, Atlassian 연결 확인, 사용자가 승인한 게시로 제한됩니다.

## 현재 구현 상태

| 기능 | 상태 |
| --- | --- |
| 로컬 오디오 가져오기 → 전사 → 회의록 생성 → SwiftData 저장 | 구현 및 자동 테스트 완료 |
| 기존 `meetings.sqlite` → SwiftData 마이그레이션 | 구현 및 자동 테스트 완료 |
| 마이크 녹음, 시스템 오디오 캡처, 일시정지·재개, 트랙 합성 | 구현됨. 실제 권한 흐름은 별도 확인 필요 |
| EventKit 캘린더 감지와 회의 앱 감지 | 구현됨. 기본은 자동 녹음이 아닌 사용자 확인 |
| SwiftUI 회의 목록·상세·전사문·메뉴바·Crux 캡슐 | 구현됨 |
| Preview Viewer와 게시 전 품질·검열 게이트 | 구현 및 자동 테스트 완료 |
| Confluence 게시, Jira 이슈 생성, 상호 링크 | 구현됨. 앱 Settings에서 Atlassian 계정을 연결한다. 라이브 게시는 미완료 |
| 녹음 중 실시간 자막·초안 요약 (전사 모델만, 화자 구분 없음) | 구현 및 자동 테스트 완료 |
| 화자 구분 | 미구현 |

`swift test`는 모델을 내려받지 않고 파이프라인·저장소·UI 상태·오디오 합성·게시 게이트를 검증합니다.

## 요구 환경

- macOS 15 이상
- Swift 6.2
- MLX Metal 셰이더를 빌드할 수 있는 Xcode와 Metal Toolchain

Metal Toolchain이 없다면 한 번 설치합니다.

```sh
xcodebuild -downloadComponent MetalToolchain
swift build
swift test
```

첫 실행 전에 모델을 내려받을 네트워크가 필요합니다. 모델을 미리 설치한 뒤에는 오프라인으로 처리할 수 있습니다.

## 빌드 및 실행

테스트와 기본 SwiftPM 빌드:

```sh
swift build
swift test
```

MLX Metal 리소스를 포함한 실행 파일은 `xcodebuild`로 빌드합니다.

```sh
xcodebuild -scheme meetingctl -destination 'platform=OS X,arch=arm64' \
  -derivedDataPath .xcbuild -configuration Debug -skipMacroValidation build

xcodebuild -scheme crux -destination 'platform=OS X,arch=arm64' \
  -derivedDataPath .xcbuild -configuration Debug -skipMacroValidation build
```

마이크·캘린더·화면 기록 권한은 앱 번들에서 받는 편이 안전합니다. 앱 번들을 만들고 실행합니다.

```sh
make app
open .xcbuild/Crux.app
```

`make app`은 `Info.plist`, MLX Metal 리소스, 앱 아이콘을 넣고 `Apple Development: imtophun@gmail.com` 인증서로 서명합니다. 기본 번들 식별자는
`local.crux.app`이며, 다른 인증서와 식별자가 필요하면 `CODESIGN_IDENTITY`와 `BUNDLE_ID`를 지정할 수 있습니다.

DMG가 필요하면 다음을 실행합니다.

```sh
make dmg
```

## 저장소 및 기존 SQLite 마이그레이션

회의 데이터는 `MeetingPersistence`의 SwiftData 모델과 `ModelContext`로 저장합니다. GRDB는 더 이상 사용하지
않습니다. 오디오 바이트는 저장하지 않고 파일 경로와 메타데이터만 보관합니다.

기존 버전의 `meetings.sqlite`를 사용 중이라면 앱이 처음 열릴 때 다음 순서로 옮깁니다.

1. 기존 SQLite 파일을 읽기 전용으로 엽니다.
2. 전체 저장소 데이터를 임시 SwiftData 저장소에 저장합니다.
3. 모든 저장이 성공하면 `<이름>.swiftdata`로 이동합니다.

마이그레이션이 중간에 실패하면 `ModelContext` 변경을 롤백하고 임시 저장소를 삭제합니다. 원본
`meetings.sqlite`는 덮어쓰거나 삭제하지 않으므로 다음 실행에서 재시도하거나 복구용으로 보관할 수 있습니다.
마이그레이션이 끝난 뒤에는 `.swiftdata` 저장소를 직접 사용하며, 기존 SQLite 파일은 백업으로 남습니다.

## 모델

앱의 설정·온보딩에서 모델을 설치하거나 CLI로 기본 모델 상태를 확인할 수 있습니다.

```sh
M=.xcbuild/Build/Products/Debug/meetingctl
$M models
$M models --install
```

기본 모델은 다음과 같습니다.

| 용도 | 기본 모델 | 저장 위치 |
| --- | --- | --- |
| 음성 인식 | `openai_whisper-large-v3-v20240930_turbo` | `~/Library/Application Support/Crux/models` |
| 회의록 생성 | `mlx-community/Qwen3-8B-4bit` | `~/Library/Application Support/Crux/models/mlx` |

앱에서는 Whisper `626MB`·`large-v3`와 Qwen3 `4B`·`8B`·`14B` 선택지를 제공합니다. 모델은 기기 메모리에 맞춰 선택하세요.

## CLI

`meetingctl`은 GUI 없이 파이프라인을 검증하고 회의 데이터를 관리하는 명령줄 도구입니다.

```sh
M=.xcbuild/Build/Products/Debug/meetingctl

# 오디오 파일을 전사하고 회의록까지 생성
$M run --audio ~/Desktop/meeting.m4a --title "주간 회의" --out ~/Desktop/out --verbose

# 전사만 수행하거나 저장된 전사문으로 회의록을 다시 생성
$M transcribe --audio ~/Desktop/meeting.m4a
$M note --meeting <회의-UUID>

# 목록·출력·재처리
$M list
$M show --meeting <회의-UUID> --format md
$M retry --meeting <회의-UUID>

# 마이크 녹음 후 회의록 생성
$M record --seconds 60 --title "주간 회의"

# 캘린더와 회의 감지 결과 확인
$M calendar --hours 6

# 오디오 보관 상태 확인 및 정리
$M retention
$M retention --policy days30 --sweep

# 회의와 연결 데이터를 삭제
$M delete --meeting <회의-UUID> --yes

# 완전 오프라인 처리: 필요한 모델을 로컬 디렉터리로 지정
$M run --audio meeting.m4a --offline \
  --llm-directory ~/models/Qwen3-8B-4bit
```

인식 힌트가 필요하면 `--vocabulary`를 사용할 수 있습니다. 힌트는 전사 구간 분할에 영향을 줄 수 있으므로 기본값은 비활성입니다.

Atlassian 연동은 앱 Settings의 Atlassian 항목에서 사이트·이메일·API 토큰을 연결하거나, CLI로 인증 정보를 등록한 뒤 Preview로 내용을 확인하고 `--yes`로 승인합니다. 토큰은 Keychain에만 저장됩니다.

```sh
# API 토큰은 프롬프트(stdin)로만 입력
$M auth --site your-team.atlassian.net --email you@example.com
$M auth --verify

# 실제 전송 없이 게시 내용과 품질 검증 결과 확인
$M preview --meeting <회의-UUID> --space TEAM --project PROJ

# 승인한 회의록 게시 및 Jira 이슈 생성
$M publish --meeting <회의-UUID> --space TEAM --project PROJ --yes
```

CLI의 전체 명령과 옵션은 다음으로 확인할 수 있습니다.

```sh
$M --help
$M <command> --help
```

## 주요 동작

### 회의 감지와 녹음

EventKit으로 macOS 캘린더 일정을 읽고, 실행 중인 Zoom·Meet·Teams·Slack·Webex 등의 회의 앱과 마이크 사용 여부를 확인합니다.
종일 일정·취소된 일정·참석자가 부족한 일정은 기본적으로 제외합니다. 같은 일정에 중복으로 묻지 않으며, 감지 후 녹음은 사용자가 직접 시작합니다.

마이크 녹음은 필수이고 시스템 오디오는 선택 사항입니다. 시스템 오디오 권한이 없으면 마이크만으로 계속 녹음합니다. 녹음은 다음 트랙으로 저장되고,
합성 트랙을 전사에 사용합니다.

```text
<회의 디렉터리>/raw/microphone.m4a
<회의 디렉터리>/raw/system.m4a
<회의 디렉터리>/mixed/meeting.m4a
```

### 회의록 검토와 게시

앱의 상세 화면에서 회의록과 전사문을 전환해 보고, 회의록 제목·결정사항·액션 아이템을 수정할 수 있습니다. 근거 타임스탬프를 누르면 해당 시점의 오디오를 재생합니다.

Preview Viewer에서는 다음 내용을 게시 전에 검토·수정합니다.

- 회의록 본문
- Jira 액션 아이템, 이슈 유형, 우선순위, 담당자, 기한
- Confluence Space와 Jira Project
- 근거와 품질 경고

Confluence와 Jira 게시물에는 전체 전사문·오디오·근거 전용 메타데이터·타임스탬프·내부 UUID와 `contentId`를 넣지 않습니다. 회의록 본문 자체가 근거 문장과 같을 수는 있으며, 게시 직전 검열 게이트가 이 구분을 포함해 한 번 더 검사합니다.

## 데이터와 개인정보

기본 데이터 위치는 `~/Library/Application Support/Crux`입니다.

| 데이터 | 위치 및 처리 |
| --- | --- |
| 회의·전사문·회의록·캘린더 메타데이터 | 로컬 SwiftData와 회의별 디렉터리 |
| 오디오 | 회의별 디렉터리. SwiftData에는 경로와 메타데이터만 저장 |
| 근거 타임스탬프·원문 인용 | 로컬 `{meetingId}.evidence.json`과 SwiftData 회의록 항목의 `evidenceJSON` |
| Atlassian API 토큰 | macOS Keychain |

오디오 보관 기간은 `immediate`, `days7`, `days30`, `days90`, `forever` 중에서 선택할 수 있습니다. 기본값은 30일이며, 오디오가 삭제되어도 전사문·회의록·근거는 남습니다. 처리에 실패한 회의의 오디오는 자동으로 삭제하지 않습니다.

## 현재 제한

- 실제 마이크·캘린더·화면 기록 권한을 승인한 뒤의 실기기 흐름은 자동 테스트에 포함되지 않습니다.
- Atlassian 라이브 게시, 오프라인 네트워크 차단 상태의 전체 실행, 60분 회의 실측, 16GB 장비 성능 측정은 별도 검증이 필요합니다.
- 화자 구분은 아직 지원하지 않습니다.
- 실시간 자막은 오디오 조각을 모은 뒤 나타나므로 몇 초 늦고, 녹음 중 요약은 초안입니다. 종료 후 기존 전체 파이프라인이 최종 전사·회의록을 만듭니다.
- 회의 품질은 오디오와 모델에 따라 달라질 수 있으며, 실제 회의 데이터셋을 이용한 정량 평가는 아직 없습니다.

## 저장소 구조

```text
Package.swift
Sources/
  MeetingCore/          도메인 모델·추론 정책·한국어 윤문·게시 초안
  MeetingPersistence/   SwiftData 저장소 및 기존 SQLite 마이그레이션
  MeetingAudio/         오디오 가져오기·캡처·믹싱
  MeetingCalendar/      EventKit·회의 앱 감지
  MeetingTranscription/ WhisperKit 전사
  MeetingInference/     MLX Swift·Qwen3 추론
  MeetingPipeline/      처리 오케스트레이션·보관·근거·게시 준비
  MeetingPublishing/    Atlassian API 연동
  MeetingUI/            SwiftUI 화면·Crux·Preview Viewer
  MeetingApp/           앱 조립 지점
  MeetingCLI/           meetingctl 명령
Tests/                   모델 없이 실행되는 자동 테스트
Fixtures/                한국어 회의 픽스처
scripts/                 앱·DMG 패키징 스크립트
docs/                    설계·개인정보·Skill·평가 문서
```

자세한 내용은 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), [docs/PRIVACY-NETWORK.md](docs/PRIVACY-NETWORK.md),
[docs/SKILLS.md](docs/SKILLS.md), [docs/EVALUATION.md](docs/EVALUATION.md)를 참고하세요.
