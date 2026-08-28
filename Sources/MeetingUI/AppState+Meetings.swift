import Foundation

public extension AppState {
    /// 제목이 다른 회의를 사용자가 직접 같은 시리즈로 묶는다.
    func groupMeetings(_ firstId: UUID, with secondId: UUID) {
        do {
            try repository.groupMeetings(firstId, with: secondId)
            statusMessage = "관련 회의로 묶었습니다."
            errorMessage = nil
            loadDetail()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 삭제 확인을 요청한다. 확인 없이는 지우지 않는다.
    func requestDelete(meetingId: UUID) {
        pendingDeletion = summaries.first { $0.id == meetingId }
    }

    func cancelDelete() {
        pendingDeletion = nil
    }

    /// 회의를 삭제한다. 오디오·전사문·회의록·근거 파일이 함께 사라진다(파일은 휴지통).
    func confirmDelete() {
        guard let target = pendingDeletion else { return }
        pendingDeletion = nil
        guard !isProcessing else {
            statusMessage = "처리 중에는 삭제할 수 없습니다. 끝난 뒤에 다시 시도하세요."
            return
        }
        do {
            let summary = try deleter.delete(meetingId: target.id)
            if selectedMeetingId == target.id {
                selectedMeetingId = nil
                detail = nil
            }
            var message = "‘\(summary.meetingTitle)’를 삭제했습니다. 파일은 휴지통으로 보냈습니다."
            if !summary.keptExternalFiles.isEmpty {
                message += " 가져온 원본 파일 \(summary.keptExternalFiles.count)개는 그대로 두었습니다."
            }
            statusMessage = message
            errorMessage = nil
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
