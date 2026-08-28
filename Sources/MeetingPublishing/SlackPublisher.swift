import Foundation
import MeetingCore

/// 승인한 액션만 Slack 채널/DM으로 보낸다.
///
/// 규칙
/// - 사용자가 보낼 때 한 번 더 확인하지 않으면 거부한다(`confirmed`가 아니면 전송하지 않는다).
/// - 전송 직전에 검열 게이트를 실행한다. 위반이 있으면 아무것도 보내지 않는다.
/// - 본문에는 액션만 넣는다. 전사·오디오·근거 타임스탬프는 타입에 존재하지 않는다.
/// - API 호출은 앱이 실행한다. 모델이 직접 호출하지 않는다.
public struct SlackPublisher: Sendable {
    private let client: any SlackMessaging
    private let log: (@Sendable (String) -> Void)?

    public init(client: any SlackMessaging, log: (@Sendable (String) -> Void)? = nil) {
        self.client = client
        self.log = log
    }

    /// - Parameters:
    ///   - payload: Preview에서 고른 액션만 담은 초안
    ///   - evidence: 로컬 근거 파일 (검열 게이트 기준)
    ///   - confirmed: 보내기 직전 확인을 마쳤는지
    public func send(
        payload: SlackActionPayload,
        evidence: EvidenceBundle,
        confirmed: Bool
    ) async throws -> SlackPostedMessage {
        guard confirmed else { throw PublishError.notApproved }
        let destination = payload.normalizedDestination
        guard !destination.isEmpty else { throw PublishError.missingDestination }
        guard !payload.actions.isEmpty else { throw PublishError.nothingToPublish }

        try audit(payload, evidence: evidence)

        let posted = try await client.postMessage(channel: destination, text: payload.messageText())
        log?("Slack 전송: \(posted.channel)")
        return posted
    }

    /// 실제 전송 본문에 대해 검열 게이트를 실행한다.
    public func audit(_ payload: SlackActionPayload, evidence: EvidenceBundle) throws {
        let violations = PublishRedaction.audit(text: payload.messageText(), evidence: evidence)
        guard violations.isEmpty else {
            throw PublishError.redactionFailed(violations)
        }
    }

    /// 전송하지 않고 보낼 본문만 만들어 본다 (Preview·검증용).
    public func dryRun(payload: SlackActionPayload, evidence: EvidenceBundle) throws -> String {
        try audit(payload, evidence: evidence)
        var lines: [String] = []
        lines.append("[Slack] 액션 \(payload.actions.count)개 (전사·오디오·타임스탬프 없음)")
        if !payload.normalizedDestination.isEmpty {
            lines.append("destination=\(payload.normalizedDestination)")
        }
        lines.append(payload.messageText())
        return lines.joined(separator: "\n")
    }
}
