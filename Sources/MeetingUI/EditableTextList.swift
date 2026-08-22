import MeetingCore
import SwiftUI

/// 결정사항·리스크·미해결처럼 "한 줄 글" 목록을 고치는 화면.
///
/// 회의록은 초안이고 사용자가 고친 내용이 최종본이다(§11).
/// 편집을 눌러야 입력칸이 열리고, 저장하기 전에는 원본을 건드리지 않는다.
/// 근거는 화면에서 지우지 않는다 — 항목을 지우면 그 근거도 함께 사라지지만 전사문 원본은 남는다.
struct EditableTextList: View {
    let title: String
    /// 표시용 항목. 본문과 근거를 함께 받는다.
    let items: [(text: String, evidence: [Evidence])]
    let segments: [TranscriptSegment]
    var onSeek: ((TimeInterval) -> Void)?
    /// 저장을 누르면 바뀐 본문을 원본 위치와 함께 돌려준다.
    /// 위치를 같이 주지 않으면 중간 항목을 지웠을 때 근거가 엉뚱한 항목에 붙는다.
    let onSave: ([EditedText]) -> Void

    @State private var isEditing = false
    @State private var drafts: [Draft] = []

    private struct Draft: Identifiable {
        let id = UUID()
        var text: String
        /// 원본 목록에서의 위치. 새로 추가한 항목은 nil이다.
        var originalIndex: Int?
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                if isEditing {
                    editor
                } else {
                    reader
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    private var header: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            if isEditing {
                Button("취소") { isEditing = false }
                    .buttonStyle(.bordered)
                Button("저장") {
                    let cleaned = drafts
                        .map { EditedText(text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), originalIndex: $0.originalIndex) }
                        .filter { !$0.text.isEmpty }
                    onSave(cleaned)
                    isEditing = false
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("편집", systemImage: "pencil") { beginEditing() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var reader: some View {
        VStack(alignment: .leading, spacing: 12) {
            if items.isEmpty {
                Text("\(title)이 없습니다.").foregroundStyle(.secondary)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.text).textSelection(.enabled)
                    EvidenceView(evidence: item.evidence, segments: segments, onSeek: onSeek)
                }
                Divider()
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach($drafts) { $draft in
                HStack(alignment: .top, spacing: 8) {
                    TextField("내용", text: $draft.text, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1 ... 6)
                    Button {
                        drafts.removeAll { $0.id == draft.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("이 항목 삭제")
                }
            }
            Button("항목 추가", systemImage: "plus") {
                drafts.append(Draft(text: "", originalIndex: nil))
            }
            .buttonStyle(.borderless)
            Text("저장하면 회의록 문서와 내보내기에 바로 반영됩니다. 지운 항목의 근거도 함께 사라집니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func beginEditing() {
        drafts = items.enumerated().map { Draft(text: $0.element.text, originalIndex: $0.offset) }
        if drafts.isEmpty {
            drafts = [Draft(text: "", originalIndex: nil)]
        }
        isEditing = true
    }
}

/// 고친 글 한 줄. 원본에서 어디 있던 항목인지 함께 들고 다닌다.
struct EditedText {
    var text: String
    var originalIndex: Int?
}

/// 고친 목록을 원본과 합친다. 자리를 지킨 항목은 근거를 그대로 물려받는다.
func mergeEdits<T>(
    _ edits: [EditedText],
    into originals: [T],
    make: (String) -> T,
    update: (String, T) -> T
) -> [T] {
    edits.map { edit in
        if let index = edit.originalIndex, originals.indices.contains(index) {
            return update(edit.text, originals[index])
        }
        return make(edit.text)
    }
}

/// 요약처럼 여러 줄 글 하나를 고치는 화면.
struct EditableParagraph: View {
    let title: String
    let text: String
    let placeholder: String
    let onSave: (String) -> Void

    @State private var isEditing = false
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if isEditing {
                    Button("취소") { isEditing = false }
                        .buttonStyle(.bordered)
                    Button("저장") {
                        onSave(draft)
                        isEditing = false
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("편집", systemImage: "pencil") {
                        draft = text
                        isEditing = true
                    }
                    .buttonStyle(.bordered)
                }
            }
            if isEditing {
                TextEditor(text: $draft)
                    .font(.body)
                    .frame(minHeight: 120)
                    .padding(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            } else {
                Text(text.isEmpty ? placeholder : text)
                    .foregroundStyle(text.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
            }
        }
    }
}
