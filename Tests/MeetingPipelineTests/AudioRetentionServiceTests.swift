import AVFoundation
import Foundation
import Testing
@testable import MeetingCore
@testable import MeetingPersistence
@testable import MeetingPipeline

@Suite("오디오 보관 적용")
struct AudioRetentionServiceTests {
    struct Harness {
        var repository: MeetingRepository
        var service: AudioRetentionService
        /// 회의 저장 디렉터리
        var storage: URL
        /// 회의 디렉터리 밖 (사용자가 가져온 원본을 흉내 낸다)
        var outside: URL
    }

    func makeHarness() throws -> Harness {
        let database = try AppDatabase.inMemory()
        let repository = MeetingRepository(database: database)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("retention-tests-\(UUID().uuidString)", isDirectory: true)
        let storage = root.appendingPathComponent("meeting", isDirectory: true)
        let outside = root.appendingPathComponent("user-files", isDirectory: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        return Harness(
            repository: repository,
            service: AudioRetentionService(repository: repository),
            storage: storage,
            outside: outside
        )
    }

    /// 마이크·시스템·합성 트랙을 갖춘 회의를 만든다.
    @discardableResult
    func makeMeeting(
        _ harness: Harness,
        endedDaysAgo: Double = 0,
        completed: Bool = true,
        withNote: Bool = true,
        externalMicrophone: Bool = false
    ) throws -> Meeting {
        let ended = Date().addingTimeInterval(-endedDaysAgo * 86_400)
        let meeting = Meeting(
            title: "보관 테스트",
            startedAt: ended.addingTimeInterval(-600),
            endedAt: ended,
            status: completed ? .completed : .transcribing,
            storageDirectory: harness.storage
        )
        try harness.repository.save(meeting)

        let micDirectory = externalMicrophone ? harness.outside : harness.storage
        let tracks: [AudioTrack] = try [
            (AudioTrackKind.microphone, try TestAudio.makeSilentFile(directory: micDirectory)),
            (AudioTrackKind.system, try TestAudio.makeSilentFile(directory: harness.storage)),
            (AudioTrackKind.mixed, try TestAudio.makeSilentFile(directory: harness.storage)),
        ].map { kind, url in
            AudioTrack(
                meetingId: meeting.id,
                kind: kind,
                fileURL: url,
                duration: 1,
                sampleRate: 16000,
                channelCount: 1,
                byteSize: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            )
        }
        try harness.repository.save(tracks: tracks)
        if withNote {
            try harness.repository.save(note: MeetingNote(meetingId: meeting.id, title: "회의록", summary: "요약"))
        }
        return meeting
    }

    func kinds(_ harness: Harness, _ meeting: Meeting) throws -> Set<AudioTrackKind> {
        Set(try harness.repository.tracks(meetingId: meeting.id).map(\.kind))
    }

    @Test("회의록 생성 후 원본 트랙만 지우고 합성본은 남긴다")
    func discardsRawKeepsMixed() throws {
        let harness = try makeHarness()
        let meeting = try makeMeeting(harness)
        let before = try harness.repository.tracks(meetingId: meeting.id)
        let raw = before.filter { $0.kind != .mixed }
        let mixed = try #require(before.first { $0.kind == .mixed })

        let outcome = try harness.service.applyAfterProcessing(meetingId: meeting.id, policy: .standard)

        #expect(outcome.trashedFileCount == 2)
        #expect(try kinds(harness, meeting) == [.mixed])
        #expect(FileManager.default.fileExists(atPath: mixed.fileURL.path))
        for track in raw {
            #expect(!FileManager.default.fileExists(atPath: track.fileURL.path))
        }
    }

    @Test("즉시 삭제 설정은 합성본까지 지운다")
    func immediateDiscardsAll() throws {
        let harness = try makeHarness()
        let meeting = try makeMeeting(harness)
        let outcome = try harness.service.applyAfterProcessing(
            meetingId: meeting.id,
            policy: AudioRetentionPolicy(retention: .immediate)
        )
        #expect(outcome.trashedFileCount == 3)
        #expect(try harness.repository.tracks(meetingId: meeting.id).isEmpty)
    }

    @Test("계속 보관 설정은 아무것도 지우지 않는다")
    func keepEverything() throws {
        let harness = try makeHarness()
        let meeting = try makeMeeting(harness)
        let outcome = try harness.service.applyAfterProcessing(meetingId: meeting.id, policy: .keepEverything)
        #expect(outcome.isEmpty)
        #expect(try kinds(harness, meeting).count == 3)
    }

    @Test("회의 디렉터리 밖의 원본은 지우지 않고 남긴다 — 사용자가 가져온 파일이다")
    func keepsExternalFiles() throws {
        let harness = try makeHarness()
        let meeting = try makeMeeting(harness, externalMicrophone: true)
        let external = try #require(
            try harness.repository.tracks(meetingId: meeting.id).first { $0.kind == .microphone }
        )

        let outcome = try harness.service.applyAfterProcessing(meetingId: meeting.id, policy: .standard)

        #expect(outcome.keptExternalFiles == [external.fileURL.standardizedFileURL])
        #expect(FileManager.default.fileExists(atPath: external.fileURL.path))
        // 파일을 남겼으므로 기록도 남긴다.
        #expect(try kinds(harness, meeting) == [.microphone, .mixed])
    }

    @Test("보관 기간이 지난 회의의 오디오를 쓸어 담는다")
    func sweepsExpired() throws {
        let harness = try makeHarness()
        let old = try makeMeeting(harness, endedDaysAgo: 40)
        let recent = try makeMeeting(harness, endedDaysAgo: 3)

        let outcome = try harness.service.sweep(policy: .standard)

        #expect(outcome.meetingCount == 1)
        #expect(try harness.repository.tracks(meetingId: old.id).isEmpty)
        #expect(try harness.repository.tracks(meetingId: recent.id).count == 3)
    }

    @Test("회의록이 없으면 오래돼도 오디오를 남긴다 — 재처리의 유일한 수단이다")
    func neverSweepsIncomplete() throws {
        let harness = try makeHarness()
        let stuck = try makeMeeting(harness, endedDaysAgo: 400, completed: false, withNote: false)
        let outcome = try harness.service.sweep(policy: .standard)
        #expect(outcome.isEmpty)
        #expect(try harness.repository.tracks(meetingId: stuck.id).count == 3)
    }

    @Test("상태만 완료이고 회의록 행이 없으면 지우지 않는다")
    func requiresNoteRow() throws {
        let harness = try makeHarness()
        let meeting = try makeMeeting(harness, endedDaysAgo: 400, completed: true, withNote: false)
        _ = try harness.service.sweep(policy: .standard)
        #expect(try harness.repository.tracks(meetingId: meeting.id).count == 3)
    }

    @Test("디스크 실측은 기록 없는 파일까지 센다 — 설정 화면이 실제 용량을 보여야 한다")
    func reportsDiskUsageIncludingUntracked() throws {
        let harness = try makeHarness()
        let meeting = try makeMeeting(harness)
        // 기록 없이 남은 잔여 파일 (폴더 이동·복구 중 생길 수 있다)
        let orphan = try TestAudio.makeSilentFile(seconds: 2.0, directory: harness.storage)

        let disk = try harness.service.diskUsage(root: harness.storage)
        let tracked = try harness.repository.tracks(meetingId: meeting.id)

        #expect(disk.fileCount == tracked.count + 1)
        #expect(disk.untrackedFileCount == 1)
        let orphanBytes = Int64((try orphan.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        #expect(disk.untrackedBytes == orphanBytes)
        #expect(disk.bytes > disk.untrackedBytes)
    }

    @Test("사용량 집계는 저장된 트랙 용량을 더한다")
    func reportsUsage() throws {
        let harness = try makeHarness()
        let meeting = try makeMeeting(harness)
        let usage = try harness.repository.audioStorageUsage()
        let expected = try harness.repository.tracks(meetingId: meeting.id).reduce(Int64(0)) { $0 + $1.byteSize }
        #expect(usage.trackCount == 3)
        #expect(usage.bytes == expected)
    }
}
