# Phase 0 조사와 Phase 1 계획·검증 기록

## Phase 0. 프로젝트 조사

### 저장소 초기 상태

- 작업 디렉터리는 git 저장소이나 **커밋이 하나도 없는 빈 저장소**였다.
  원격만 연결돼 있고 기본 브랜치는 `main`.
- README, AGENTS.md, 기존 개발 규칙, 기존 코드·의존성 없음. 따라서 프로젝트 구조를 새로 제안했다.
- 사용자 전역 규칙(`~/.claude/CLAUDE.md`)의 작업 원칙(조사 우선, 검증 후 완료 보고, 저자와 검토 분리)을 따랐다.

### 개발 환경 (실측)

| 항목 | 값 |
| --- | --- |
| OS | macOS 26.5.1 (Darwin 25.5.0) |
| Xcode | 26.0.1 (17A400), macOS SDK 26.0 |
| Swift | 6.2 |
| 하드웨어 | Apple M4 Pro, 48GB |

목표 환경은 macOS 15+ / 16GB이므로, 메모리 제약은 개발 장비에서 자동으로 드러나지 않는다.
그래서 제약을 **구조와 테스트로 강제**하고(모델 동시 상주 금지), 단계별 RSS를 로그로 남기도록 했다.

### 의존성 조사 (실제 매니페스트·소스 확인)

| 패키지 | 버전 | 확인한 내용 |
| --- | --- | --- |
| `argmaxinc/argmax-oss-swift` | 1.1.0 | 제품 `WhisperKit`. `WhisperKitConfig(model:downloadBase:modelFolder:download:)`, `transcribeWithResults(audioPaths:audioInputOptions:decodeOptions:)`, `unloadModels()`. `DecodingOptions.chunkingStrategy = .vad`, `wordTimestamps`. `TranscriptionSegment`은 `start`/`end`/`avgLogprob`/`noSpeechProb`/`words` 제공. `AudioInputOptions.audioLoadingMode = .incremental`로 긴 파일 스트리밍 |
| `ml-explore/mlx-swift-lm` | 3.31.4 | **LLM 라이브러리가 `mlx-swift-examples`에서 이 저장소로 이동**했다. `MLXLLM`에 `Qwen3.swift` 존재. `loadModelContainer(from:using:configuration:)`, `ChatSession(_:instructions:generateParameters:additionalContext:)`, `respond(to:)`. `additionalContext`가 채팅 템플릿 인자로 전달되므로 `enable_thinking` 사용 가능 |
| `ml-explore/mlx-swift` | 0.31.4 | `MLX.GPU.set(cacheLimit:)`, `clearCache()`, `activeMemory`/`peakMemory` |
| `huggingface/swift-transformers` | 1.3.3 | `Tokenizers.AutoTokenizer` + Jinja 템플릿. `MLXHuggingFace`의 `#huggingFaceTokenizerLoader()` 매크로가 이 어댑터를 생성 |
| `huggingface/swift-huggingface` | 0.8.1 | `HubClient(cache: HubCache(cacheDirectory:))`. 모델 스냅샷 다운로드 전용 |
| `groue/GRDB.swift` | 7.11.1 | 마이그레이션, `FetchableRecord`/`PersistableRecord` |

모델 저장소도 확인했다.

- WhisperKit large-v3 turbo의 실제 식별자는 `openai_whisper-large-v3-v20240930_turbo`
  (`argmaxinc/whisperkit-coreml`에 존재). 양자화판 `..._626MB`도 있다.
- `mlx-community/Qwen3-4B-4bit` 존재 확인(사고 모드 전환이 가능한 원본 Qwen3-4B).
  `Qwen3-4B-Instruct-2507-4bit`은 쓰지 않는다.

## 기술 리스크와 대응

| 리스크 | 실제 발생 여부 | 대응 |
| --- | --- | --- |
| **MLX Swift가 SwiftPM CLI에서 빌드되지 않음** | **발생.** `swift build`로 만든 실행 파일이 런타임에 `Failed to load the default metallib`로 실패. mlx-swift README에 "SwiftPM CLI는 Metal 셰이더를 빌드할 수 없다"고 명시 | Metal Toolchain 설치(`xcodebuild -downloadComponent MetalToolchain`, 704MB) 후 `xcodebuild`로 실행 파일 빌드. 라이브러리·테스트는 계속 `swift build`/`swift test`로 빠르게 돈다. 이 제약을 README에 명시 |
| mlx-swift-lm 매크로 신뢰 | 발생 | `xcodebuild -skipMacroValidation` |
| `@main` + `main.swift` 충돌 | 발생 | CLI 진입 파일명을 `MeetingCTL.swift`로 변경 |
| Qwen3 사고 모드 전환 경로 불확실 | 미발생(경로 확인) | `additionalContext: ["enable_thinking": ...]` + 비사고 모드에서 `/no_think` 소프트 스위치 병행. 어느 쪽이든 `<think>` 블록은 파서에서 무조건 제거 |
| LLM JSON 출력 불안정 | 상시 리스크 | 관용 추출·복구 + 스키마 기본값 + 1회 복구 재요청 + 단계별 폴백 |
| 근거 위조 | 상시 리스크 | 짧은 식별자 + 인용 원문 검증 + 최종 단계 번호 참조만 허용 |
| 16GB에서 두 모델 동시 상주 | 구조로 차단 | `ModelLifecycleCoordinator` + 동시 상주 금지 테스트 |
| 긴 회의 메모리 | 부분 검증 | WhisperKit `incremental` 로딩, 5~10분 창 분할(단위 테스트로 60분 규모 검증). 실제 60분 오디오 실측은 미완 |
| Swift 6 엄격 동시성 | 발생 | `sending` 클로저 파라미터로 해결. 엔진·UI 타깃만 Swift 5 언어 모드 |

## Phase 1 구현 계획과 결과

목표 흐름: `로컬 오디오 파일 선택 → WhisperKit 전사 → Qwen3 요약 → 사담 제거 → 회의록 JSON 저장 → SwiftUI 표시`

| 단계 | 산출물 | 상태 |
| --- | --- | --- |
| 1. 패키지·모듈 골격 | `Package.swift`, 9개 모듈 | 완료 |
| 2. 도메인 모델 | `Meeting`…`ProcessingJob` | 완료 |
| 3. 추론 정책 | 청커, 라우터, 사담 정책, 근거 검증, 중복 통합, 프롬프트, 파서 3종, 파이프라인 | 완료 |
| 4. 저장소 | GRDB 스키마·마이그레이션·저장소 2종 | 완료 |
| 5. 엔진 | WhisperKit 엔진, Qwen3 MLX 엔진 | 완료 |
| 6. 오케스트레이션 | 모델 수명 관리, 처리 파이프라인, 가져오기 | 완료 |
| 7. UI | 목록·상세 7탭·액션아이템 편집·메뉴바·설정 | 완료 |
| 8. CLI 하네스 | `meetingctl run/transcribe/note/list/show/retry` | 완료 |
| 9. 테스트 | 83개 (Core 62, Pipeline 9, Persistence 12) | 완료 |
| 10. 문서 | README, 설계, 개인정보, 평가 | 완료 |

## 검증 기록

측정 장비: Apple M4 Pro, 48GB, macOS 26.5.1. 목표 환경(16GB)에서의 실측은 별도로 필요하다.

### 자동 테스트

```
$ swift build
Build complete!

$ swift test
✔ Test run with 83 tests in 16 suites passed after 0.072 seconds.
```

모델 없이 도는 테스트가 다루는 범위: 사고 모드 자동 라우팅, 사담 제거 분류, 반복 발언 통합,
결정과 제안 구분, 근거 타임스탬프 연결, 위조 인용 제거, LLM JSON 파싱 실패·복구, 60분 규모 창 분할,
회의 상태 전이, 전사 실패 후 재시도, 앱 강제 종료 후 재처리(전사문 재사용), 손상 오디오,
모델 동시 상주 금지, 저장소 왕복·검색·원본 오디오 삭제.

### 실제 모델 E2E

한국어 회의 음성 픽스처를 `say -v Yuna`로 만들어 사용했다(118초, 결정·액션·리스크·미해결 질문·
사담·모호 표현·일정 변경이 섞인 대본). 대본과 생성 방법은 `Fixtures/`에 있다.

| 단계 | 결과 |
| --- | --- |
| WhisperKit 전사 | 성공. 24개 구간. 모델 로드 197초(첫 실행 Core ML 특화 포함) + 전사 204.6초, 프로세스 최대 RSS 1.60GB |
| 모델 교체 순서 | 로그로 확인: `음성 인식 모델 해제 후 LLM 로드` → `WhisperKit 해제` |
| Qwen3 회의록 생성 | 성공. 모델 로드 1.2초(캐시), 사고 모드 재검토 7건, 최종 종합 사고 모드 |

전사 결과 일부(원문 대조):

```
[00:00] 안녕하세요. 다들 잘 지내셨죠? 오늘 비가 많이 와서 오는데 좀 늦었습니다.
[00:24] 오늘 안건은 결제 모듈 개편 배포 일정과 서버 용량 이슈입니다.
[01:05] 그럼 결제 모듈 배포는 3월 12일 수요일로 확정합니다.
```

#### 최종 E2E 측정 (모델 캐시 이후)

```
$ meetingctl run --audio Fixtures/sample-meeting-ko.aiff --title "결제 모듈 배포 회의" --verbose
[prepareAudio]  0.00s  rss=29MB   peak=29MB
[transcribe]   15.27s  rss=275MB  peak=280MB
[extractFacts] 126.30s rss=2462MB peak=2490MB
[persistNote]   0.00s  rss=2462MB peak=2490MB
총 소요 141.6초 (오디오 118초 → 약 1.2배 실시간)
구간 30개
[model] Qwen3 해제, MLX active=0MB
```

- 전사 15.3초는 Core ML 특화 캐시가 살아 있는 두 번째 실행 기준이다. 첫 실행은 모델 다운로드와
  특화 때문에 197초가 더 걸렸다.
- LLM 단계 최대 RSS 2.49GB, MLX active 약 2.16GB(Qwen3-4B 4-bit). 전사 단계 최대 280MB.
  **두 모델이 동시에 올라간 시점은 없다**(해제 로그로 확인).
- 처리가 끝나면 `MLX active=0MB`로 내려간다.

#### 생성된 회의록 (실제 출력)

```markdown
## 요약
결제 모듈 배포 일정을 3월 12일로 확정하고, 배포 체크리스트는 다음 주 월요일까지 공유해야 합니다.
회귀 테스트는 화요일 오전까지 완료해야 하며, 서버 CPU 사용률이 85%까지 오를 수 있으며 트래픽 증가로
용량 초과 위험이 있습니다. 가격 정책과 사업팀 확인이 미정입니다.

## 결정사항
- 결제 모듈 배포 일정을 3월 12일 수요일로 확정합니다. (근거: 00:32, 00:38)
- 배포 체크리스트는 다음 주 월요일까지 작성하여 공유해야 합니다. (근거: 00:42)

## 액션아이템
| 작업 | 담당자 | 마감일 | 상태 | 근거 |
| 배포 체크리스트 작성 및 공유 | 홍길동 | 다음 주 월요일 (추가 확인 필요) | 제안 | 00:42 |
| 회귀 테스트 완료 | 카팀 | 화요일 오전 (추가 확인 필요) | 제안 | 00:50 |

## 리스크·이슈
- 배포 후 서버 CPU 사용률이 85%까지 오를 수 있습니다. (근거: 01:00)
- 배포 후 트래픽이 20% 증가하여 서버 용량 초과 위험입니다. (근거: 01:04)

## 미해결 질문
- 가격 정책은 아직 정해지지 않았습니다. (근거: 01:19)
- 사업팀 확인이 필요합니다. (근거: 01:22)
```

동시에 남은 로그:

```
[마감일] 원문에서 확인되지 않는 날짜라 확정하지 않음: 2024-03-10 (근거에 없는 값: 2024,03,10)
[최종] 검증된 후보에 없는 마감일 값 무시(후보의 일정 표현을 사용): 다음 주 월요일
[사담] 제외 구간에서만 근거가 나온 후보 제거: 다음 주 금요일 회식은 다들 가능하시나요?
```

완료 기준 대비 확인 결과

| 완료 기준 | 결과 |
| --- | --- |
| 로컬 오디오 파일을 선택할 수 있다 | 앱 툴바·메뉴바의 파일 선택, CLI `--audio` |
| WhisperKit으로 전사할 수 있다 | 30구간 전사 성공 |
| Qwen3-4B로 회의록을 생성할 수 있다 | 결정·액션·리스크·미해결 질문 생성 성공 |
| 사담이 결과에서 제거된다 | 인사·순대국·회식·맞장구 모두 회의록에 없음. 제외 구간 후보 제거 로그 확인 |
| 결정사항과 액션아이템에 근거 타임스탬프가 연결된다 | 모든 항목에 근거 시각 표시 |
| 생성된 회의록을 SwiftUI에서 확인할 수 있다 | 구현 완료, 앱 실행 확인. **화면 렌더링은 육안 검증 못 함** (아래 참고) |
| 회의 데이터가 외부로 전송되지 않는다 | 앱 코드에 네트워크 호출 0건(`docs/PRIVACY-NETWORK.md`) |

### 검증하지 못한 것

- **GUI 화면 렌더링.** `xcodebuild -scheme Crux` 빌드 성공, 실제 회의록이 들어 있는 데이터베이스로
  앱을 실행해 프로세스가 정상 유지되는 것(크래시·오류 로그 없음, DB 열기 성공)까지는 확인했다.
  다만 터미널에 화면 기록 권한이 없어 `screencapture`가 검은 화면만 반환했고, 목록·상세 탭이 실제로 어떻게
  보이는지는 눈으로 확인하지 못했다. 앱을 직접 실행해 확인이 필요하다.
- **오프라인 전체 기능**(모델 캐시 후 네트워크 차단), **60분 회의 실측**, **16GB 장비 측정**,
  **§16 품질 지표 20건 평가**.

### 실제 실행에서 발견해 고친 결함

E2E를 돌려 보고 나서야 드러난 문제들이다. 모두 테스트로 고정했다.

1. **회의의 유일한 결정사항이 사라졌다.** 1차 추출이 원문을 살짝 바꿔 인용("그렇면 배포일은…")했고,
   근거 검증이 그 인용을 버려서 근거가 빈 항목이 됐다. 사고 모드 재검토는 근거 없는 항목을 폐기했다.
   → 인용이 원문과 조금 달라도 **지목된 구간의 원문으로 대체**해 근거 자체를 잃지 않게 했고,
   재검토 프롬프트에 "근거만 잘못됐으면 폐기하지 말고 바로잡아라"를 넣었다.
2. **모델이 마감일을 만들어냈다.** "다음 주 월요일"을 `2023-03-07`, `2024-03-10`으로 바꿨다.
   → `DueDateGrounding`이 근거 인용·구간 원문에 없는 날짜를 거부하고 원문 표현만 남긴다.
3. **사담이 미해결 질문으로 새어 나왔다.** "회식 일정 확정 여부"가 회의록에 들어갔다.
   → 제외 구간에서만 근거가 나온 후보를 버린다. 모델이 `CONDENSE`로 올려준 순수 사담도 규칙이 제외로 내린다.
4. **인식 힌트가 전사 분할을 망쳤다.** `--vocabulary`를 주니 118초가 24구간 → 6구간(구간당 145~166자)으로
   합쳐져 근거가 뭉뚝해지고 1차 추출이 실패했다.
   → 스펙의 `TranscriptSegmenter`를 구현해 90자를 넘는 구간을 문장 단위로 나눈다(시각은 글자 수 비율 배분).
   `--vocabulary`는 기본 비활성이며 위험을 README에 적었다.
5. **사고 모드가 토큰을 다 써서 회의록이 비었다.** 최종 종합을 사고 모드로 돌릴 때 사고 과정이 출력 예산을
   전부 먹으면 JSON이 남지 않고, 형식 복구 요청도 고칠 본문이 없어 빈 회의록이 됐다.
   → 사고 모드에 토큰 예산 1.8배를 주고, 본문이 비면 **같은 작업을 비사고 모드로 다시** 시킨다.

### 남아 있는 품질 문제 (수정하지 않음)

1. 같은 항목이 결정사항과 액션아이템에 중복으로 나온다("배포 체크리스트는 월요일까지"). 프롬프트에 금지
   규칙을 넣었지만 완전히 없어지지 않았다.
2. "QA팀"이 "카팀"으로 전사되고 그 값이 담당자로 들어간다. 원문 근거는 있으나 실제로는 담당 미정이다.
3. "3월 13일 목요일로 변경될 가능성"이 회의록에 반영되지 않았다. 일정 변경 가능성은 보존 대상이다.
4. 액션아이템 상태가 근거가 있어도 `제안`으로 남는다. 확정 판정 규칙을 더 다듬어야 한다.

이 항목들은 §16 평가에서 정량화한 뒤 프롬프트·정책을 조정하는 것이 맞다고 판단해 이번 범위에서는 남겨 두었다.

## 다음 단계 (Phase 2 이후)

1. **Phase 2 오디오 캡처** — `AVAudioEngine` 마이크 캡처, `ScreenCaptureKit` 시스템 오디오 캡처,
   트랙 분리 저장, mixed 생성, 권한 처리, 장치 연결 해제 복구. `.app` 번들과 사용 설명·코드 서명 포함.
2. **60분 회의 실측** — 처리 시간, 최대 RSS, OOM 여부. 16GB 장비에서 측정.
3. **§16 품질 평가** — 실제 회의 20건으로 결정·액션 누락률, 사담 포함률, 중요 맥락 삭제율 측정
   (`docs/EVALUATION.md`).
4. **화자 구분** — `SpeakerKit`(argmax-oss-swift에 포함)으로 `speakerId` 채우기 검토.
