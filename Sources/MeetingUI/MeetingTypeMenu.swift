import MeetingCore
import SwiftUI

/// 녹음·가져오기에서 회의 유형을 고르는 메뉴 항목.
public struct MeetingTypeButtons: View {
    public var action: (MeetingType) -> Void

    public init(action: @escaping (MeetingType) -> Void) {
        self.action = action
    }

    public var body: some View {
        ForEach(MeetingType.allCases, id: \.self) { type in
            Button(type.menuTitle) { action(type) }
        }
    }
}
