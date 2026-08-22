import AppKit
import Foundation
import MeetingCore

/// 실행 중인 회의 앱과 마이크 사용 여부를 확인한다.
///
/// 화면이나 오디오 내용을 읽지 않는다. 실행 중인 앱 목록과 기본 입력 장치 상태만 본다.
public struct ConferenceAppDetector: Sendable {
    public init() {}

    public func detect() -> [ConferenceAppSignal] {
        let inputInUse = InputDeviceActivity.isInputInUse()
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        return NSWorkspace.shared.runningApplications.compactMap { application in
            guard application.activationPolicy == .regular,
                  let bundleId = application.bundleIdentifier
            else { return nil }
            guard ConferenceAppSignal.knownConferenceApps.contains(where: {
                bundleId.caseInsensitiveCompare($0) == .orderedSame
                    || (application.localizedName?.caseInsensitiveCompare($0) == .orderedSame)
            }) else { return nil }

            return ConferenceAppSignal(
                appName: application.localizedName ?? bundleId,
                isFrontmost: bundleId == frontmost,
                // 마이크가 실제로 쓰이는 중일 때만 오디오 사용으로 본다.
                usesAudio: inputInUse
            )
        }
    }
}
