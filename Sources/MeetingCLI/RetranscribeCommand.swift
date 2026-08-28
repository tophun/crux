import ArgumentParser
import Foundation
import MeetingCore
import MeetingPersistence
import MeetingPipeline

/// 저장된 회의에서 시간 구간만 다시 전사한다. 기본은 회의록을 다시 만들지 않는다.
struct RetranscribeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "retranscribe",
        abstract: "선택한 시간 구간만 다시 전사한다. 기본은 전사문만 바꾸고 회의록은 유지한다."
    )

    @OptionGroup var options: CommonOptions

    @Option(name: .long, help: "회의 UUID")
    var meeting: String

    @Option(name: .long, help: "시작 시각(초)")
    var from: Double

    @Option(name: .long, help: "끝 시각(초)")
    var to: Double

    @Flag(name: .long, help: "선택 구간의 회의록 항목만 다시 뽑는다. 없으면 전사만 한다.")
    var notes: Bool = false

    func run() async throws {
        guard let meetingId = UUID(uuidString: meeting) else {
            throw ValidationError("회의 UUID 형식이 아닙니다: \(meeting)")
        }
        let database = try options.makeDatabase()
        let pipeline = options.makePipeline(database: database)
        let result = try await pipeline.retranscribeRange(
            meetingId: meetingId,
            startTime: from,
            endTime: to,
            reextractNotes: notes
        ) { update in
            FileHandle.standardError.write(Data("[\(Int(update.fraction * 100))%] \(update.message)\n".utf8))
        }
        print("구간 \(result.segments.count)개")
        for segment in result.segments {
            print("[\(TimeFormat.stamp(segment.startTime))-\(TimeFormat.stamp(segment.endTime))] \(segment.text)")
        }
        if notes {
            print("")
            print(MeetingNoteExporter.markdown(result.note))
        }
    }
}
