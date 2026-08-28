import Foundation
import MeetingCore
import MeetingPipeline

/// 녹음 중 실시간 자막·초안 요약. 전사 모델만 쓰고, 실패해도 녹음은 계속된다.
extension MeetingSessionCoordinator {
    /// 녹음이 시작된 뒤 자막 세션을 켠다. 모델 로드 실패는 자막만 포기한다.
    func startLiveCaptions(meetingId: UUID) async {
        liveCaptions = LiveCaptionState(isDraft: true, isActive: true)
        let models = await pipeline.modelLifecycle
        let session = LiveCaptionSession(
            meetingId: meetingId,
            source: capture,
            models: models,
            onUpdate: { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.liveCaptions = state
                    self?.persistLiveDraft(state, meetingId: meetingId)
                }
            },
            log: log
        )
        captionSession = session
        await session.start()
    }

    /// 자막 세션을 멈추고, 필요하면 초안을 회의 폴더에 남긴다.
    func stopLiveCaptions(persist: Bool, meetingId: UUID? = nil) async {
        guard let session = captionSession else {
            liveCaptions.isActive = false
            return
        }
        captionSession = nil
        let final = await session.stop()
        liveCaptions = final
        guard persist else { return }
        persistLiveDraft(final, meetingId: meetingId ?? activeMeetingId)
    }

    func persistLiveDraft(_ state: LiveCaptionState, meetingId: UUID?) {
        guard let meetingId, !state.lines.isEmpty else { return }
        guard let meeting = try? repository.meeting(id: meetingId) else { return }
        do {
            try LiveCaptionDraftStore.write(state, to: meeting.storageDirectory)
        } catch {
            log?("실시간 자막 초안 저장 실패: \(error.localizedDescription)")
        }
    }
}
