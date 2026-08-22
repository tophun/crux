import Foundation
import MeetingCore

/// 오디오 캡처 권한 상태. UI에 그대로 표시한다(§11).
public enum CapturePermissionState: String, Sendable, CaseIterable {
    case notDetermined
    case granted
    case denied
    case restricted

    public var displayName: String {
        switch self {
        case .notDetermined: "확인 필요"
        case .granted: "허용됨"
        case .denied: "거부됨"
        case .restricted: "제한됨"
        }
    }
}

public enum CaptureState: String, Sendable {
    case idle
    case recording
    case paused
    case stopping
}

/// 녹음 서비스 추상화.
///
/// Phase 1(현재)은 로컬 오디오 파일 가져오기만 지원한다.
/// 마이크(`AVAudioEngine`)와 시스템 오디오(`ScreenCaptureKit`) 캡처는 Phase 2에서 이 프로토콜을 구현한다.
/// 구현체가 없는 상태를 명시적으로 남겨 두어, 캡처 기능이 동작하는 것처럼 보이지 않게 한다.
public protocol AudioCaptureService: Sendable {
    var state: CaptureState { get async }

    func microphonePermission() async -> CapturePermissionState
    func systemAudioPermission() async -> CapturePermissionState

    func start(meetingId: UUID, storage: MeetingStorage) async throws
    func pause() async throws
    func resume() async throws
    /// 녹음을 끝내고 저장된 트랙을 반환한다.
    func stop() async throws -> [AudioTrack]
}
