import CoreAudio
import Foundation

/// 기본 입력 장치가 지금 사용 중인지 확인한다.
///
/// 회의 앱이 실제로 마이크를 쓰고 있는지 판단해, 캘린더에 없는 회의도 감지할 수 있게 한다.
/// 오디오를 읽거나 저장하지 않고 장치 상태만 본다.
public enum InputDeviceActivity {
    public static func isInputInUse() -> Bool {
        guard let deviceId = defaultInputDeviceId() else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceId, &address, 0, nil, &size, &isRunning)
        return status == noErr && isRunning != 0
    }

    static func defaultInputDeviceId() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceId = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceId
        )
        guard status == noErr, deviceId != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return deviceId
    }
}
