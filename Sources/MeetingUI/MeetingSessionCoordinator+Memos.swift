import Foundation
import MeetingAudio
import MeetingCalendar
import MeetingCore

/// 녹음 중 노치에서 남기는 메모.
extension MeetingSessionCoordinator {
    /// 녹음 중 메모를 남긴다. 빈 문자열은 무시하고, 녹음 경과 시각을 함께 기록한다.
    public func addMemo(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let memoStore else { return }
        var elapsed: TimeInterval = 0
        if case let .recording(seconds, _) = capsule {
            elapsed = seconds
        }
        let memo = MeetingMemo(elapsed: elapsed, text: trimmed)
        memos.append(memo)
        do {
            try memoStore.save(memos)
        } catch {
            lastError = error.localizedDescription
            log?("메모 저장 실패: \(error.localizedDescription)")
        }
    }
}
