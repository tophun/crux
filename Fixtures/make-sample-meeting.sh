#!/bin/bash
# 한국어 회의 음성 픽스처 생성.
#
# 실제 회의 녹음 없이 전사·회의록 파이프라인을 검증하기 위한 합성 음성이다.
# 대본에는 결정사항, 액션아이템(담당자·마감일), 리스크, 미해결 질문, 사담,
# 모호한 표현("일단 보류"), 일정 변경 가능성이 섞여 있다.
#
# 사용법: ./Fixtures/make-sample-meeting.sh [출력경로]
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$DIR/sample-meeting-ko.aiff}"

say -v Yuna -r 175 -o "$OUT" -f "$DIR/sample-meeting-ko.txt"
echo "생성: $OUT"
afinfo "$OUT" | grep -E "duration|Data format" || true
