import Foundation
@testable import MeetingCore
import Testing

@Suite("플로팅 노트와 예전 시각 슬롯 메모")
struct MeetingMemoStoreTests {
    @Test("memos.json은 그대로 읽고, 노트 파일은 따로 저장한다")
    func keepsHourlyMemosAndStoresNoteSeparately() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("crux-note-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = MeetingMemoStore(storageDirectory: directory)
        let hourly = [
            MeetingMemo(elapsed: 12, text: "다음 단계를 확인"),
            MeetingMemo(elapsed: 65, text: "배포는 수요일")
        ]
        try store.save(hourly)

        #expect(store.loadNote() == nil)
        #expect(store.load().map(\.text) == ["다음 단계를 확인", "배포는 수요일"])

        let note = CruxNote(title: "Project Update", body: "Confirm the next steps")
        try store.saveNote(note)

        #expect(store.load().map(\.text) == ["다음 단계를 확인", "배포는 수요일"])
        let loaded = store.loadNote()
        #expect(loaded?.title == "Project Update")
        #expect(loaded?.body == "Confirm the next steps")
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("memos.json").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("crux-note.json").path))
    }

    @Test("노트 본문이 있으면 그 값을 쓰고, 없으면 시각 슬롯 메모를 이어 붙인다")
    func seedsBodyFromNoteOrHourlyMemos() {
        let memos = [
            MeetingMemo(elapsed: 12, text: "다음 단계를 확인"),
            MeetingMemo(elapsed: 65, text: "배포는 수요일")
        ]
        #expect(MeetingMemo.readableTranscript(memos) == "0:12  다음 단계를 확인\n1:05  배포는 수요일")
        #expect(CruxNote.seedBody(note: nil, memos: memos) == "0:12  다음 단계를 확인\n1:05  배포는 수요일")
        #expect(CruxNote.seedBody(note: CruxNote(title: "A", body: ""), memos: memos) == "0:12  다음 단계를 확인\n1:05  배포는 수요일")
        #expect(CruxNote.seedBody(note: CruxNote(title: "A", body: "본문"), memos: memos) == "본문")
        #expect(CruxNote.seedBody(note: nil, memos: []).isEmpty)
    }
}
