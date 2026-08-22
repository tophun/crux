# 검증용 픽스처

| 파일 | 설명 |
| --- | --- |
| `sample-meeting-ko.txt` | 한국어 회의 대본. 결정·액션·리스크·미해결 질문·사담·모호 표현·일정 변경이 섞여 있다 |
| `make-sample-meeting.sh` | macOS `say -v Yuna`로 대본을 음성(약 118초)으로 만든다 |

생성된 오디오 파일은 저장소에 커밋하지 않는다(스크립트로 언제든 재생성할 수 있다).

```sh
./Fixtures/make-sample-meeting.sh
.xcbuild/Build/Products/Debug/meetingctl run \
  --audio Fixtures/sample-meeting-ko.aiff --title "결제 모듈 배포 회의" --verbose
```

대본에서 회의록이 담아야 하는 것

- 결정: 결제 모듈 배포일을 3월 12일 수요일로 확정
- 액션: 홍길동 — 배포 체크리스트 작성·공유 (마감 "다음 주 월요일" = 모호 → `dueDate` null, 표현 보존)
- 액션: QA 회귀 테스트 화요일 오전까지 (담당자 미지정 → `assignee` null)
- 리스크: 결제 서버 CPU 피크 85%, 배포 후 트래픽 20% 증가 시 한계
- 제안(결정 아님): 증설 비용 월 300만 원 — "일단 보류하고 다음 주 재논의"
- 미해결: 가격 정책 미정, 사업팀 확인 필요
- 일정 변경 가능성: 3월 13일 목요일로 변경 가능, 최종 확정은 월요일 회의

회의록에 없어야 하는 것

- 날씨·지각 인사, 순대국 이야기, 회식 일정, 단순 맞장구
