import ArgumentParser
import Foundation
import MeetingCore
import MeetingPersistence
import MeetingPipeline
import MeetingPublishing

/// Slack 토큰 관리와 승인된 액션 전송. 모델은 이 명령을 호출하지 않는다.
struct SlackCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "slack",
        abstract: "승인한 액션만 Slack으로 보낸다 (토큰은 Keychain, 전사·오디오는 전송하지 않음)",
        subcommands: [Auth.self, Send.self]
    )
}

extension SlackCommand {
    static func printDryRun(bundle: PublishBundle, evidence: EvidenceBundle) {
        print("=== Slack (승인한 액션만, 전송 없음) ===")
        do {
            let slack = SlackPublisher(client: SlackClient(credentials: SlackCredentials(botToken: "")))
            try print(
                slack.dryRun(
                    payload: SlackActionPayload.make(from: bundle, destination: ""),
                    evidence: evidence
                )
            )
        } catch {
            print("Slack 검열 게이트에서 중단됨: \(error.localizedDescription)")
        }
    }

    /// 토큰은 명령 인자로 받지 않고 stdin으로만 받는다.
    struct Auth: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "auth",
            abstract: "Slack 봇 토큰을 Keychain에 저장·확인·삭제 (토큰은 stdin으로만 입력)"
        )

        @Flag(name: .long, help: "저장된 토큰을 삭제한다")
        var delete = false

        @Flag(name: .long, help: "저장된 토큰으로 연결을 확인한다")
        var verify = false

        func run() async throws {
            let store = SlackKeychainCredentialStore()

            if delete {
                try store.delete()
                print("저장된 Slack 인증 정보를 삭제했습니다.")
                return
            }

            if !verify {
                FileHandle.standardError.write(
                    Data("Slack 봇 토큰을 입력하고 Enter를 누르세요 (화면에 표시되지 않도록 붙여넣기 후 바로 Enter):\n".utf8)
                )
                guard let token = readLine(strippingNewline: true), !token.isEmpty else {
                    throw ValidationError("토큰이 입력되지 않았습니다.")
                }
                let credentials = SlackCredentials(botToken: token)
                try store.save(credentials)
                print("저장했습니다: \(credentials.redactedDescription)")
            }

            guard let credentials = try SlackChainedCredentialStore().load() else {
                print("저장된 Slack 인증 정보가 없습니다. 토큰을 입력해 다시 실행하세요.")
                return
            }
            print("현재 인증 정보: \(credentials.redactedDescription)")

            if verify {
                let client = SlackClient(credentials: credentials)
                let name = try await client.verifyConnection()
                print("연결 확인 완료: \(name)")
            }
        }
    }

    struct Send: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "send",
            abstract: "Preview에서 고른 액션만 Slack 채널/DM으로 보낸다"
        )

        @OptionGroup var options: CommonOptions

        @Option(name: .long) var meeting: String
        @Option(name: .long, help: "채널 또는 DM (예: C0123 또는 #eng)")
        var channel: String
        @Option(name: .long, help: "Confluence Space 키 (미리보기 묶음 구성용)")
        var space: String = "TEAM"
        @Option(name: .long, help: "Jira Project 키 (미리보기 묶음 구성용)")
        var project: String = "PROJ"
        @Flag(name: .long, help: "전송을 승인한다. 이 플래그 없이는 보내지 않는다.")
        var yes = false

        func run() async throws {
            guard let meetingId = UUID(uuidString: meeting) else {
                throw ValidationError("회의 UUID 형식이 아닙니다.")
            }
            guard yes else {
                throw ValidationError("보내려면 --yes 로 한 번 더 승인해야 합니다. 먼저 `preview`로 액션을 확인하세요.")
            }
            guard let credentials = try SlackChainedCredentialStore().load() else {
                throw ValidationError("Slack 인증 정보가 없습니다. `meetingctl slack auth` 로 등록하세요.")
            }

            let database = try options.makeDatabase()
            let preparation = PublishPreparation(
                repository: MeetingRepository(database: database),
                calendar: CalendarRepository(database: database),
                publishRecords: PublishRecordRepository(database: database)
            )
            let prepared = try preparation.prepare(
                meetingId: meetingId,
                options: PublishBundleBuilder.Options(spaceKey: space, projectKey: project)
            )
            let payload = SlackActionPayload.make(from: prepared.bundle, destination: channel)
            let verbose = options.verbose
            let publisher = SlackPublisher(
                client: SlackClient(credentials: credentials) { message in
                    if verbose {
                        FileHandle.standardError.write(Data(("[slack] " + message + "\n").utf8))
                    }
                }
            )
            let posted = try await publisher.send(
                payload: payload,
                evidence: prepared.evidence,
                confirmed: true
            )
            print("Slack: \(posted.channel)")
        }
    }
}
