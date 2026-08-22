import Foundation
import MeetingCore

/// 승인된 회의록을 Confluence·Jira에 게시한다.
///
/// 규칙
/// - 사용자가 승인한 회의록과 액션 아이템만 전송한다(`approved`가 아니면 거부).
/// - 게시 직전에 검열 게이트를 실행한다. 위반이 있으면 아무것도 보내지 않는다.
/// - 전체 녹취록·음성 파일·근거 타임스탬프는 전송 대상 타입에 존재하지 않는다.
/// - API 호출은 앱이 실행한다. 모델이 직접 호출하지 않는다.
public struct MeetingPublisher: Sendable {
    public struct Outcome: Sendable {
        public var pageId: String
        public var pageURL: String
        public var pageTitle: String
        /// contentId → (issueKey, url)
        public var issues: [(contentId: String, key: String, url: String)]
        /// 게시하지 못한 항목과 이유
        public var problems: [String]
    }

    private let client: AtlassianClient
    private let log: (@Sendable (String) -> Void)?

    public init(client: AtlassianClient, log: (@Sendable (String) -> Void)? = nil) {
        self.client = client
        self.log = log
    }

    /// - Parameters:
    ///   - bundle: Preview Viewer에서 사용자가 검토·수정한 게시 묶음
    ///   - evidence: 로컬 근거 파일 (검열 게이트 기준)
    ///   - approved: 사용자가 게시를 승인했는지
    public func publish(
        bundle: PublishBundle,
        evidence: EvidenceBundle,
        approved: Bool
    ) async throws -> Outcome {
        guard approved else { throw PublishError.notApproved }

        var page = bundle.page
        let issues = bundle.includedIssues
        var problems: [String] = []

        // 1. 검열 게이트 — 실제로 보낼 본문으로 검사한다.
        try audit(page: page, issues: issues, evidence: evidence)

        // 2. Confluence 페이지 생성
        let spaceId = try await client.confluenceSpaceId(key: bundle.spaceKey)
        let created = try await client.createConfluencePage(
            spaceId: spaceId,
            title: page.title,
            storageBody: page.storageBody()
        )
        log?("Confluence 페이지 생성: \(created.id)")

        // 3. Jira 이슈 생성
        var createdIssues: [(contentId: String, key: String, url: String)] = []
        for issue in issues {
            do {
                var accountId: String?
                if let query = issue.assigneeQuery {
                    accountId = try await client.findJiraAccountId(query: query)
                    if accountId == nil {
                        problems.append("Jira 사용자를 찾지 못해 담당자를 비웠습니다: \(query)")
                    }
                }
                let result = try await client.createJiraIssue(
                    projectKey: issue.projectKey,
                    summary: issue.summary,
                    descriptionADF: issue.descriptionADF(),
                    issueTypeName: issue.issueTypeName,
                    accountId: accountId,
                    dueDate: issue.dueDate,
                    priorityName: issue.priorityName
                )
                createdIssues.append((issue.contentId, result.key, result.url))
                log?("Jira 이슈 생성: \(result.key)")

                // 4. 이슈 → 회의록 링크
                do {
                    try await client.addJiraRemoteLink(
                        issueKey: result.key,
                        url: created.url,
                        title: created.title
                    )
                } catch {
                    problems.append("이슈 \(result.key)에 회의록 링크를 붙이지 못했습니다: \(error.localizedDescription)")
                }
            } catch {
                problems.append("이슈 생성 실패(\(issue.summary.prefix(20))): \(error.localizedDescription)")
            }
        }

        // 5. 회의록 → 이슈 링크 (페이지 본문 갱신)
        var finalPage = created
        if !createdIssues.isEmpty {
            page.linkedIssueKeys = createdIssues.map(\.key)
            do {
                try audit(page: page, issues: issues, evidence: evidence)
                finalPage = try await client.updateConfluencePage(
                    pageId: created.id,
                    title: page.title,
                    storageBody: page.storageBody(),
                    currentVersion: created.version
                )
            } catch {
                problems.append("회의록에 Jira 링크를 추가하지 못했습니다: \(error.localizedDescription)")
            }
        }

        return Outcome(
            pageId: finalPage.id,
            pageURL: finalPage.url,
            pageTitle: finalPage.title,
            issues: createdIssues,
            problems: problems
        )
    }

    /// 실제 전송 본문에 대해 검열 게이트를 실행한다.
    func audit(page: ConfluencePageDraft, issues: [JiraIssueDraft], evidence: EvidenceBundle) throws {
        var payload = page.storageBody()
        for issue in issues {
            payload += issue.summary
            payload += issue.detailParagraphs.joined(separator: " ")
            if let data = try? JSONSerialization.data(withJSONObject: issue.descriptionADF()) {
                payload += String(decoding: data, as: UTF8.self)
            }
        }
        let violations = PublishRedaction.audit(text: payload, evidence: evidence)
        guard violations.isEmpty else {
            throw PublishError.redactionFailed(violations)
        }
    }

    /// 게시하지 않고 보낼 본문만 만들어 본다 (Preview·검증용).
    public func dryRun(bundle: PublishBundle, evidence: EvidenceBundle) throws -> String {
        try audit(page: bundle.page, issues: bundle.includedIssues, evidence: evidence)
        var lines: [String] = []
        lines.append("[Confluence] space=\(bundle.spaceKey) title=\(bundle.page.title)")
        lines.append(bundle.page.storageBody())
        for issue in bundle.includedIssues {
            lines.append(
                "[Jira] project=\(issue.projectKey) type=\(issue.issueTypeName) "
                    + "assignee=\(issue.assigneeQuery ?? "미지정") due=\(issue.dueDate ?? "미지정")"
            )
            lines.append("  \(issue.summary)")
            for paragraph in issue.detailParagraphs {
                lines.append("  - \(paragraph)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
