import Foundation
import Testing
@testable import MeetingCore

@Suite("전사문 분할")
struct TranscriptChunkerTests {
    @Test("짧은 회의는 하나의 창으로 처리한다")
    func singleWindowForShortMeeting() {
        let windows = TranscriptChunker().windows(for: Fixtures.meetingSegments)
        #expect(windows.count == 1)
        #expect(windows[0].segments.count == 9)
    }

    @Test("빈 전사문은 창을 만들지 않는다")
    func emptyInput() {
        #expect(TranscriptChunker().windows(for: []).isEmpty)
    }

    @Test("60분 회의는 5~10분 창으로 나뉘고 각 창이 문자 예산을 넘지 않는다")
    func splitsOneHourMeeting() {
        // 60분, 12초 간격 300개 구간 (구간당 약 80자)
        let segments = (0..<300).map { index in
            TranscriptSegment(
                meetingId: Fixtures.meetingId,
                index: index,
                startTime: TimeInterval(index) * 12,
                endTime: TimeInterval(index) * 12 + 11,
                text: String(repeating: "회의 내용 발언 ", count: 10),
                confidence: 0.9
            )
        }
        let chunker = TranscriptChunker()
        let windows = chunker.windows(for: segments)

        #expect(windows.count > 1)
        #expect(windows.map(\.segments.count).reduce(0, +) == 300)
        for window in windows {
            let characters = window.segments.reduce(0) { $0 + $1.text.count }
            #expect(characters <= chunker.configuration.maxCharacters + 200)
            #expect(window.duration <= chunker.configuration.maxDuration + 12)
        }
        // 창 사이 맥락이 이어진다.
        #expect(windows[1].contextSegments.count == 2)
    }

    @Test("프롬프트 전사문에는 짧은 식별자와 타임스탬프가 들어간다")
    func promptContainsShortIds() {
        let window = Fixtures.window(Fixtures.meetingSegments)
        let text = window.promptTranscript()
        #expect(text.contains("S2 ["))
        #expect(text.contains("00:20"))
        #expect(window.segment(forShortId: "s2")?.index == 2)
    }
}

@Suite("긴 전사 구간 분할")
struct TranscriptSegmenterTests {
    let segmenter = TranscriptSegmenter()

    @Test("짧은 구간은 그대로 둔다")
    func keepsShortSegments() {
        let segments = Fixtures.meetingSegments
        let result = segmenter.split(segments)
        #expect(result.count == segments.count)
        #expect(result.map(\.text) == segments.map(\.text))
        #expect(result.map(\.index) == Array(0..<segments.count))
    }

    @Test("여러 문장이 뭉친 긴 구간을 문장 단위로 나누고 시각을 배분한다")
    func splitsLongSegment() {
        // 실제 실행에서 관찰된 형태: 인식 힌트를 주면 구간이 이렇게 합쳐진다.
        let long = TranscriptSegment(
            meetingId: Fixtures.meetingId,
            index: 0,
            startTime: 37,
            endTime: 51,
            text: "그럼 결제 모듈 배포는 3월 12일 수요일로 확정합니다. 박지훈님이 배포 체크리스트를 작성해서 다음주 월요일까지 공유해주세요. 그리고 QA는 화요일 오전까지 회귀 테스트를 마쳐야 합니다.",
            confidence: 0.9
        )
        let result = segmenter.split([long])

        #expect(result.count == 3)
        #expect(result[0].text.contains("3월 12일"))
        #expect(result[1].text.contains("체크리스트"))
        #expect(result[2].text.contains("회귀 테스트"))
        // 시각은 원래 구간 안에서 순서대로 배분된다.
        #expect(result[0].startTime == 37)
        #expect(result[2].endTime == 51)
        #expect(result[0].endTime <= result[1].startTime + 0.001)
        #expect(result[1].endTime <= result[2].startTime + 0.001)
        #expect(result.map(\.index) == [0, 1, 2])
        // 원문은 손실 없이 보존된다.
        let rejoined = result.map(\.text).joined(separator: " ")
        #expect(rejoined.replacingOccurrences(of: " ", with: "") == long.text.replacingOccurrences(of: " ", with: ""))
    }

    @Test("종결부호가 없어도 종결어미로 나눈다")
    func splitsWithoutPunctuation() {
        let long = TranscriptSegment(
            meetingId: Fixtures.meetingId,
            index: 0,
            startTime: 0,
            endTime: 20,
            text: "지금 결제 서버 사용률이 피크에 85퍼센트까지 올라갑니다 배포 후에 트래픽이 늘어나면 한계에 걸릴 위험이 있습니다 증설 비용은 월 300만 원 정도 추가로 들어갑니다",
            confidence: 0.8
        )
        let result = segmenter.split([long])
        #expect(result.count >= 2)
        #expect(result.allSatisfy { !$0.text.isEmpty })
    }

    @Test("숫자 사이의 마침표는 문장 끝으로 보지 않는다")
    func keepsDecimalNumbers() {
        let text = "전환율이 3.5퍼센트에서 4.2퍼센트로 올랐고 이번 분기 목표는 5.0퍼센트입니다. 다음 주에 다시 확인하겠습니다."
        let pieces = segmenter.sentences(in: text)
        #expect(pieces.count == 2)
        #expect(pieces[0].contains("3.5"))
        #expect(pieces[0].contains("5.0"))
    }

    @Test("너무 짧은 조각은 앞 문장에 붙인다")
    func mergesTinyPieces() {
        #expect(segmenter.merge(["결제 모듈 배포를 확정합니다.", "네."]).count == 1)
    }
}

@Suite("전사 진행률 추정")
struct TranscriptionProgressEstimatorTests {
    let estimator = TranscriptionProgressEstimator()

    @Test("실제 진행률이 0이어도 시간이 지나면 진행률이 올라간다")
    func advancesWithTime() {
        // 118초 오디오 → 예상 처리 시간 약 23.6초
        let early = estimator.fraction(reported: 0, elapsed: 2, audioDuration: 118)
        let later = estimator.fraction(reported: 0, elapsed: 12, audioDuration: 118)
        #expect(early > 0)
        #expect(later > early)
    }

    @Test("추정만으로는 95%를 넘지 않는다")
    func capsEstimate() {
        let fraction = estimator.fraction(reported: 0, elapsed: 600, audioDuration: 118)
        #expect(fraction == 0.95)
    }

    @Test("실제 진행률이 추정보다 앞서면 실제 값을 쓴다")
    func prefersRealProgress() {
        let fraction = estimator.fraction(reported: 0.8, elapsed: 2, audioDuration: 118)
        #expect(fraction == 0.8)
    }

    @Test("실제로 끝나면 100%가 된다")
    func completes() {
        #expect(estimator.fraction(reported: 1, elapsed: 1, audioDuration: 118) == 1)
    }

    @Test("아주 짧은 오디오에서도 즉시 100%가 되지 않는다")
    func handlesShortAudio() {
        let fraction = estimator.fraction(reported: 0, elapsed: 0.5, audioDuration: 3)
        #expect(fraction < 0.3)
    }
}
