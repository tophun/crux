import Foundation
import MeetingCore
import MeetingPipeline
import MeetingPublishing

/// Preview Viewer 조립과 Confluence·Jira·Slack 전송.
public extension MeetingSessionCoordinator {
    var defaultSlackDestination: String {
        get { UserDefaults.standard.string(forKey: "slack.destination") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "slack.destination") }
    }

    func preparePreview(meetingId: UUID) {
        do {
            let prepared = try preparation.prepare(
                meetingId: meetingId,
                options: PublishBundleBuilder.Options(
                    spaceKey: defaultSpaceKey,
                    projectKey: defaultProjectKey
                )
            )
            let preparation = preparation
            let credentialStore = credentialStore
            let tracks = (try? repository.tracks(meetingId: meetingId)) ?? []
            playback.prepare(tracks: tracks)
            let model = PreviewViewerModel(
                bundle: prepared.bundle,
                evidence: prepared.evidence,
                findings: prepared.findings,
                playback: playback,
                hasAtlassianCredentials: (try? credentialStore.load()) != nil,
                publishAction: { [weak self] bundle, evidence in
                    try await Self.publishAtlassian(
                        bundle: bundle,
                        evidence: evidence,
                        meetingId: meetingId,
                        credentialStore: credentialStore,
                        preparation: preparation,
                        applyPublished: { title, count in
                            await MainActor.run { [weak self] in
                                self?.applyPublished(title: title, issueCount: count)
                            }
                        }
                    )
                },
                slackSendAction: { bundle, evidence, destination, confirmed in
                    try await Self.sendSlackActions(
                        bundle: bundle,
                        evidence: evidence,
                        destination: destination,
                        confirmed: confirmed
                    )
                },
                revalidate: { bundle in
                    MeetingQualityChecker().check(note: prepared.note, bundle: bundle, evidence: prepared.evidence)
                }
            )
            model.slackDestination = defaultSlackDestination
            previewModel = model
        } catch {
            lastError = error.localizedDescription
        }
    }

    private static func publishAtlassian(
        bundle: PublishBundle,
        evidence: EvidenceBundle,
        meetingId: UUID,
        credentialStore: any AtlassianCredentialStore,
        preparation: PublishPreparation,
        applyPublished: @escaping @Sendable (String, Int) async -> Void
    ) async throws -> [String] {
        guard let credentials = try credentialStore.load() else {
            throw PublishError.missingCredentials("설정에서 Atlassian 계정을 연결해 주세요.")
        }
        let publisher = MeetingPublisher(client: AtlassianClient(credentials: credentials))
        let outcome = try await publisher.publish(bundle: bundle, evidence: evidence, approved: true)
        try preparation.recordOutcome(outcome, meetingId: meetingId, spaceKey: bundle.spaceKey)
        await applyPublished(outcome.pageTitle, outcome.issues.count)
        return [outcome.pageURL] + outcome.issues.map(\.url)
    }

    private static func sendSlackActions(
        bundle: PublishBundle,
        evidence: EvidenceBundle,
        destination: String,
        confirmed: Bool
    ) async throws -> String {
        guard confirmed else { throw PublishError.notApproved }
        guard let credentials = try SlackChainedCredentialStore().load() else {
            throw PublishError.missingSlackCredentials("meetingctl slack auth 로 토큰을 Keychain에 저장하세요.")
        }
        let payload = SlackActionPayload.make(from: bundle, destination: destination)
        UserDefaults.standard.set(destination, forKey: "slack.destination")
        let posted = try await SlackPublisher(client: SlackClient(credentials: credentials))
            .send(payload: payload, evidence: evidence, confirmed: true)
        return "Slack \(posted.channel)"
    }
}
