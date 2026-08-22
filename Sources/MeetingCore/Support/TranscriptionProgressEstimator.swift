import Foundation

/// 전사 진행률 추정.
///
/// WhisperKit은 VAD로 나눈 구간을 동시에 처리해서 실제 진행률이 0%에서 100%로 건너뛴다.
/// 사용자에게는 멈춘 것처럼 보이므로, 실제 진행률과 경과 시간 추정 중 **큰 값**을 쓴다.
/// 추정값은 95%에서 멈춰, 실제로 끝나기 전에 100%가 되지 않게 한다.
public struct TranscriptionProgressEstimator: Sendable {
    /// 오디오 길이 대비 처리 시간 비율. Apple Silicon에서 large-v3 turbo 기준 관측값에 여유를 더한 값이다.
    public var realTimeFactor: Double
    /// 추정만으로 도달할 수 있는 상한
    public var estimateCeiling: Double
    /// 아주 짧은 오디오에서도 최소 이만큼은 걸린다고 본다(초)
    public var minimumExpectedSeconds: TimeInterval

    public init(
        realTimeFactor: Double = 0.2,
        estimateCeiling: Double = 0.95,
        minimumExpectedSeconds: TimeInterval = 3
    ) {
        self.realTimeFactor = realTimeFactor
        self.estimateCeiling = estimateCeiling
        self.minimumExpectedSeconds = minimumExpectedSeconds
    }

    /// - Parameters:
    ///   - reported: WhisperKit이 알려 준 실제 진행률 (0...1)
    ///   - elapsed: 전사 시작 후 경과 시간
    ///   - audioDuration: 오디오 길이
    public func fraction(reported: Double, elapsed: TimeInterval, audioDuration: TimeInterval) -> Double {
        let expected = max(minimumExpectedSeconds, audioDuration * realTimeFactor)
        let estimated = min(estimateCeiling, max(0, elapsed) / expected)
        let real = reported.isFinite ? min(1, max(0, reported)) : 0
        // 실제 진행률이 1이면 그대로 완료로 본다.
        return real >= 1 ? 1 : max(real, estimated)
    }
}
