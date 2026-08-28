import ArgumentParser
import Foundation
import MeetingCore
import MeetingPersistence

extension MeetingCTL {
    /// 회의 삭제. 오디오·전사문·회의록·근거 파일을 함께 지운다.
    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "회의를 삭제한다 (파일은 휴지통으로, 기록은 데이터베이스에서 삭제)"
        )

        @OptionGroup var options: CommonOptions

        @Option(name: .long, help: "회의 UUID") var meeting: String

        @Flag(name: .long, help: "파일은 남기고 데이터베이스 기록만 지운다")
        var keepFiles: Bool = false

        @Flag(name: .long, help: "확인 없이 삭제한다")
        var yes: Bool = false

        func run() throws {
            guard let meetingId = UUID(uuidString: meeting) else {
                throw ValidationError("회의 UUID 형식이 아닙니다.")
            }
            let database = try options.makeDatabase()
            let repository = MeetingRepository(database: database)
            guard let target = try repository.meeting(id: meetingId) else {
                throw ValidationError("회의를 찾을 수 없습니다: \(meeting)")
            }

            if !yes {
                print("‘\(target.title)’를 삭제합니다. 녹음 파일·전사문·회의록·근거가 모두 사라집니다.")
                print("계속하려면 --yes 를 붙여 다시 실행하세요.")
                return
            }

            let summary = try MeetingDeleter(repository: repository)
                .delete(meetingId: meetingId, removeFiles: !keepFiles)
            print("삭제 완료: \(summary.meetingTitle)")
            if summary.trashedItemCount > 0 {
                let megabytes = Double(summary.freedBytes) / 1_048_576
                print(String(format: "휴지통으로 보낸 항목 %d개 (%.1fMB)", summary.trashedItemCount, megabytes))
            }
            for kept in summary.keptExternalFiles {
                print("남겨 둔 원본 파일: \(kept.path)")
            }
        }
    }

    struct Retention: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "오디오 보관 상태를 보고, 기간이 지난 오디오를 정리한다 (전사문·회의록·근거는 유지)"
        )

        @OptionGroup var options: CommonOptions

        @Option(name: .long, help: "보관 기간: immediate | days7 | days30 | days90 | forever (기본 days30)")
        var policy: String = AudioRetentionPolicy.standard.retention.rawValue

        @Flag(name: .long, help: "실제로 정리한다. 없으면 대상만 보여 준다.")
        var sweep: Bool = false

        func run() throws {
            guard let retention = AudioRetention(rawValue: policy) else {
                throw ValidationError("보관 기간 값이 올바르지 않습니다: \(policy)")
            }
            let database = try options.makeDatabase()
            let repository = MeetingRepository(database: database)
            let rule = AudioRetentionPolicy(retention: retention)

            let service = AudioRetentionService(repository: repository, logSink: { print($0) })
            let usage = try repository.audioStorageUsage()
            let disk = try service.diskUsage()
            print("디스크의 오디오: \(ByteFormat.short(disk.bytes)) · 파일 \(disk.fileCount)개")
            print("회의 기록과 연결된 오디오: \(ByteFormat.short(usage.bytes)) · 파일 \(usage.trackCount)개")
            if disk.untrackedFileCount > 0 {
                print("기록이 없어 자동 정리되지 않는 파일: \(ByteFormat.short(disk.untrackedBytes)) · \(disk.untrackedFileCount)개")
            }
            print("보관 기간: \(retention.label) — \(retention.detail)")

            let candidates = try repository.audioRetentionCandidates()
            let expired = rule.expired(among: candidates, now: Date())
            let blocked = candidates.filter { !$0.isCompleted && $0.hasAudio }
            print("정리 대상 회의: \(expired.count)건")
            if !blocked.isEmpty {
                print("회의록이 없어 오디오를 남기는 회의: \(blocked.count)건")
            }

            guard sweep else {
                if !expired.isEmpty {
                    print("실제로 정리하려면 --sweep 를 붙이세요.")
                }
                return
            }
            let outcome = try service.sweep(policy: rule)
            print("정리 완료: 회의 \(outcome.meetingCount)건 · 파일 \(outcome.trashedFileCount)개 · \(ByteFormat.short(outcome.freedBytes)) 회수")
            for kept in outcome.keptExternalFiles {
                print("남겨 둔 원본 파일: \(kept.path)")
            }
        }
    }
}

extension MeetingType: ExpressibleByArgument {
    public init?(argument: String) {
        guard let parsed = MeetingType.parse(argument) else { return nil }
        self = parsed
    }
}
