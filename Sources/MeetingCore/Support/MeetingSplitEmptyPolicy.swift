import Foundation

/// 회의 목록·상세의 Empty 노출.
///
/// 회의가 없으면 고를 대상이 없으므로 상세 Empty는 중복이다.
/// Empty는 좌측 목록에만 두고, 상세는 선택이 있을 때만 내용을 그린다.
public enum MeetingSplitEmptyPolicy {
    /// 회의가 하나도 없을 때만 목록 Empty를 켠다.
    public static func showsListPlaceholder(meetingCount: Int) -> Bool {
        meetingCount == 0
    }

    /// 상세의 `회의를 선택하세요` Empty는 쓰지 않는다.
    public static func showsDetailPlaceholder(hasDetail _: Bool) -> Bool {
        false
    }
}
