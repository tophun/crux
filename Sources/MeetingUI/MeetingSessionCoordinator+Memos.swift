import Foundation
import MeetingCore

/// 녹음 중 플로팅 노트.
public extension MeetingSessionCoordinator {
    /// 노트 본문을 저장한다. 예전 `memos.json` 슬롯은 덮어쓰지 않는다.
    func updateNote(_ body: String) {
        guard let memoStore else { return }
        let note = CruxNote(
            title: activeMeetingTitle ?? "",
            body: body,
            updatedAt: Date()
        )
        sessionNote = note
        do {
            try memoStore.saveNote(note)
        } catch {
            lastError = error.localizedDescription
            log?("노트 저장 실패: \(error.localizedDescription)")
        }
    }
}
