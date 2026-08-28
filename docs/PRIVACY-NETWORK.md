# 개인정보와 네트워크 검토

## 네트워크 경계

Atlassian 게시 기능이 들어오면서 네트워크 경계가 바뀌었다. 현재 허용되는 외부 통신은 **세 가지뿐**이다.

| 허용 | 목적 | 나가는 것 | 통제 |
| --- | --- | --- | --- |
| 모델 다운로드 (`huggingface.co`) | WhisperKit·Qwen3 가중치 최초 다운로드 | 파일 요청만 | `--offline`, `modelFolder`, `--llm-directory`로 완전 차단 가능 |
| Confluence 게시 | 사용자가 승인한 회의록 | `ConfluencePageDraft`가 담을 수 있는 필드만 | 승인 없으면 거부, 검열 게이트 통과 필수 |
| Jira 이슈 생성 | 사용자가 승인한 액션 아이템 | `JiraIssueDraft`가 담을 수 있는 필드만 | 같음 |

**절대 나가지 않는 것**: 회의 오디오 파일, 전체 전사문, 근거 인용문, 근거 타임스탬프, 내부 UUID·contentId,
모델 프롬프트, 캘린더 원본 데이터.

## 1. 앱 코드의 네트워크 호출 (실측)

```sh
for m in MeetingCore MeetingPersistence MeetingAudio MeetingCalendar MeetingTranscription \
         MeetingInference MeetingPipeline MeetingUI MeetingApp MeetingCLI MeetingPublishing; do
  grep -rlE "URLSession|URLRequest|NWConnection|https?://[a-z]" Sources/$m | wc -l
done
```

결과: **`MeetingPublishing`의 1개 파일(`AtlassianClient.swift`)만 해당.** 다른 10개 모듈은 0건이다.

```sh
grep -rn "URLSession|URLRequest" Sources/ | grep -v "^Sources/MeetingPublishing/"
# 결과 없음
```

즉 앱에서 나가는 HTTP는 전부 `MeetingPublishing`을 지난다. 이 모듈은 오디오·전사문·근거를 담는 타입을
아예 모른다(`PublishBundle`, `EvidenceBundle`만 받는다).

의존성이 네트워크를 쓰는 지점은 그대로다.

| 지점 | 목적 | 통제 |
| --- | --- | --- |
| `WhisperKit` → `huggingface.co` | 음성 인식 모델 다운로드 | `allowDownload = false` 또는 `modelFolder` |
| `HubClient`(swift-huggingface) → `huggingface.co` | LLM 가중치·토크나이저 | `localDirectory` 지정 시 다운로더를 만들지 않음 |

`HF_ENDPOINT` 환경 변수가 있으면 그 호스트를 쓴다(swift-huggingface 기본 동작). 배포 시 확인 대상이다.

## 2. 검열 게이트 (요구사항 7)

게시 직전에 **실제로 보낼 본문**을 검사한다. 위반이 하나라도 있으면 아무것도 전송하지 않는다.

`PublishRedaction.audit(text:evidence:)`가 잡는 것

| 종류 | 검사 방법 |
| --- | --- |
| 내부 UUID | UUID 정규식 |
| 근거 인용문 | 근거 파일의 인용문(12자 이상)이 본문에 있는지 |
| 근거 타임스탬프 | 근거의 시작·종료 시각을 `mm:ss`로 만든 문자열이 본문에 있는지 |
| 내부 키 | `segmentId`, `transcript`, `evidence`, `startTime`, `endTime` |

두 단계에서 실행한다.

1. `MeetingQualityChecker` — Preview Viewer에 차단 사유로 표시
2. `MeetingPublisher.audit` — 전송 직전. 여기서 걸리면 `PublishError.redactionFailed`로 중단

**구조적 방어가 먼저다.** `ConfluencePageDraft`와 `JiraIssueDraft`에는 타임스탬프·세그먼트 ID·전사 원문을
넣을 필드가 없다. 검열 게이트는 사용자가 근거 문장을 직접 붙여 넣은 경우 같은 예외를 잡는 두 번째 방어선이다.

## 3. 근거 분리 (요구사항 7)

| 데이터 | 위치 |
| --- | --- |
| 근거 타임스탬프 + 원문 인용 | `<회의 디렉터리>/{meetingId}.evidence.json` (로컬 전용) |
| 회의록 항목 ↔ 근거 연결 | 내부 `contentId` (`D1`, `A2`, `R1`, `Q1`) — 게시물에 포함되지 않음 |
| 게시 결과 ↔ 내부 항목 연결 | 로컬 `publishRecord` 테이블 (contentId ↔ Jira 이슈 키) |
| 확인 화면 | Preview Viewer의 "근거 확인" 탭에서만 타임스탬프·원문을 본다 |

Confluence 회의록과 Jira 이슈 본문에는 근거 타임스탬프를 넣지 않는다.

## 4. 인증 정보 취급

- Atlassian API 토큰은 **Keychain**에 저장한다(`KeychainCredentialStore`).
- 앱 Settings의 Atlassian 항목에서 사이트·이메일·API 토큰을 저장하고, 연결 해제는 Keychain에서 삭제한다.
- CLI는 토큰을 명령 인자로 받지 않는다. `meetingctl auth --site ... --email ...`이 **stdin**으로만 받는다.
  (`ps`나 셸 히스토리에 토큰이 남지 않는다.)
- CI·검증용으로 `ATLASSIAN_SITE`/`ATLASSIAN_EMAIL`/`ATLASSIAN_API_TOKEN` 환경 변수도 읽는다.
- `AtlassianCredentials.redactedDescription`만 화면·로그에 쓴다. 토큰은 포함되지 않는다.
- `AtlassianClient`의 로그는 **메서드와 경로만** 남긴다. 헤더(Authorization)와 본문은 남기지 않는다.
- 감사: `grep -rn "apiToken|authorizationHeader" Sources/ | grep -iE "print|log"` → 결과 없음.

## 5. 캘린더 데이터

- EventKit으로 읽는다. **네트워크 요청이 없다.** macOS 캘린더에 구독된 Google 계정의 일정을 그대로 읽는다.
- 읽은 일정은 로컬 `calendarEvent` 테이블에만 저장한다.
- 회의록에는 캘린더의 제목·날짜·참석자만 쓴다. 참석자를 임의로 추가하지 않는다.
- 종일 일정, 취소된 일정, 참석자가 부족한 일정은 기본적으로 제외한다.
- 중복 알림 방지용으로 알림한 이벤트 ID를 `notifiedEvent` 테이블에 남긴다.

## 6. 녹음과 감지

- 마이크: `AVAudioEngine`. 권한은 `NSMicrophoneUsageDescription`으로 요청한다.
- 시스템 오디오: `ScreenCaptureKit`. 화면 영상은 저장하지 않는다(2×2 프레임을 버린다). 오디오만 파일로 쓴다.
- 회의 감지: 실행 중인 앱 목록(`NSWorkspace`)과 **기본 입력 장치 사용 여부**(`CoreAudio`의
  `kAudioDevicePropertyDeviceIsRunningSomewhere`)만 본다. 오디오 내용을 읽지 않는다.
- 기본 동작은 자동 녹음이 아니라 사용자 확인이다.

## 7. 내부 사고 내용

`<think>...</think>`는 생성 직후 제거하고 저장하지 않는다. 윤문 단계 출력도 같은 처리를 거친다.

## 8. 남은 확인 항목

- 오프라인 실행 검증(모델 캐시 후 네트워크 차단)은 절차만 정의했고 실측하지 않았다.
- 앱 자동 업데이트는 없다. 도입 시 이 문서에 항목을 추가한다.

## 오디오 보관 (단계적 축소)

오디오는 개인정보 노출 면적이 가장 큰 데이터이면서 용량도 가장 크다. 세 단계로 줄인다.

**1. 낮은 비트레이트로 기록한다.** 마이크·시스템·합성본 모두 16kHz 모노 32kbps AAC다.
음성 인식 모델의 입력이 16kHz이므로 그 이상은 전사 품질에 기여하지 않는다.
실제 녹음으로 잰 값: 34.7MB/시간 → **13.9MB/시간**.
같은 파일을 32kbps로 다시 인코딩해 전사한 결과 날짜·이름·수치·용어가 모두 그대로 나왔다.

**2. 회의록을 만들면 원본 트랙을 지운다.** 마이크·시스템 원본을 휴지통으로 보내고 합성본만 남긴다.
합성본에 두 소리가 모두 들어 있어 재생과 재처리에 충분하다. 원본+합성본 두 벌을 들고 있을 때와 비교하면 약 80% 줄어든다.

**3. 보관 기간이 지나면 오디오만 지운다.** 기본 30일이고 설정에서 즉시·7일·30일·90일·계속 보관을 고를 수 있다.
전사문·회의록·근거 파일은 이 정책과 무관하게 계속 남는다.

안전 규칙

- 파일은 **휴지통으로** 보낸다. 되돌릴 수 있어야 한다.
- **회의록이 저장된 회의만** 정리 대상이다. 처리에 실패하거나 중단된 회의의 오디오는 재시도의 유일한 수단이므로 건드리지 않는다.
- 회의 저장 디렉터리 **밖의 파일은 지우지 않는다**. 사용자가 가져온 원본은 그대로 둔다.

관련 코드: `MeetingCore/Domain/AudioRetentionPolicy.swift`(순수 판단), `MeetingPipeline/AudioRetentionService.swift`(파일 적용),
`MeetingUI/AudioStorageModel.swift`(설정·사용량). CLI로는 `meetingctl retention`으로 확인·정리한다.
