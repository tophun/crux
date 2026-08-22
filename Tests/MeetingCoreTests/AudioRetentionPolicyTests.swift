import Foundation
import Testing

@testable import MeetingCore

@Suite("오디오 보관 정책")
struct AudioRetentionPolicyTests {
    private func candidate(
        days ago: Double,
        completed: Bool = true,
        hasAudio: Bool = true,
        now: Date
    ) -> AudioRetentionPolicy.Candidate {
        AudioRetentionPolicy.Candidate(
            meetingId: UUID(),
            referenceDate: now.addingTimeInterval(-ago * 86400),
            isCompleted: completed,
            hasAudio: hasAudio
        )
    }

    @Test("기본값은 30일 보관에 원본 트랙 정리")
    func standardDefaults() {
        #expect(AudioRetentionPolicy.standard.retention == .days30)
        #expect(AudioRetentionPolicy.standard.discardRawAfterProcessing)
        #expect(AudioRetentionPolicy.standard.actionAfterProcessing() == .discardRaw)
    }

    @Test("즉시 삭제는 회의록 생성 직후 오디오를 전부 지운다")
    func immediateDiscardsAll() {
        let policy = AudioRetentionPolicy(retention: .immediate)
        #expect(policy.actionAfterProcessing() == .discardAll)
    }

    @Test("계속 보관은 아무것도 지우지 않는다")
    func keepEverything() {
        let policy = AudioRetentionPolicy.keepEverything
        #expect(policy.actionAfterProcessing() == .keep)
        let now = Date()
        #expect(policy.expired(among: [candidate(days: 3650, now: now)], now: now).isEmpty)
    }

    @Test("보관 기간 경계 — 정확히 30일이면 지우고 하루 전이면 남긴다")
    func boundary() {
        let now = Date()
        let policy = AudioRetentionPolicy(retention: .days30)
        let old = candidate(days: 30, now: now)
        let fresh = candidate(days: 29, now: now)
        let expired = policy.expired(among: [old, fresh], now: now)
        #expect(expired == [old.meetingId])
    }

    @Test("회의록이 없으면 기간이 지나도 오디오를 남긴다 — 재시도의 유일한 수단이다")
    func neverTouchesIncomplete() {
        let now = Date()
        let policy = AudioRetentionPolicy(retention: .days7)
        let stuck = candidate(days: 400, completed: false, now: now)
        #expect(policy.expired(among: [stuck], now: now).isEmpty)
    }

    @Test("오디오가 이미 없으면 대상에 넣지 않는다")
    func skipsMeetingsWithoutAudio() {
        let now = Date()
        let policy = AudioRetentionPolicy(retention: .days7)
        #expect(policy.expired(among: [candidate(days: 90, hasAudio: false, now: now)], now: now).isEmpty)
    }

    @Test("즉시 설정에서도 지난 회의를 쓸어 담는다")
    func immediateSweepsEverything() {
        let now = Date()
        let policy = AudioRetentionPolicy(retention: .immediate)
        let one = candidate(days: 0, now: now)
        #expect(policy.expired(among: [one], now: now) == [one.meetingId])
    }
}
