import Foundation
import MeetingCore
import MeetingPersistence
import MeetingPipeline
import Observation

/// 오디오 보관 설정을 저장한다.
///
/// 파이프라인이 액터 안에서 읽으므로 `UserDefaults`(스레드 안전)를 단일 저장소로 쓴다.
/// 앱 상태 객체를 참조하면 액터 경계를 넘게 되어 값을 여기서 직접 읽고 쓴다.
public enum AudioRetentionStore {
    private static let retentionKey = "audio.retention"
    private static let discardRawKey = "audio.discardRawAfterProcessing"

    /// 현재 정책. 저장된 값이 없으면 기본값(30일 보관 + 원본 정리)이다.
    public static var policy: AudioRetentionPolicy {
        get {
            let defaults = UserDefaults.standard
            let retention = defaults.string(forKey: retentionKey)
                .flatMap(AudioRetention.init(rawValue:)) ?? AudioRetentionPolicy.standard.retention
            let discardRaw = defaults.object(forKey: discardRawKey) as? Bool
                ?? AudioRetentionPolicy.standard.discardRawAfterProcessing
            return AudioRetentionPolicy(retention: retention, discardRawAfterProcessing: discardRaw)
        }
        set {
            let defaults = UserDefaults.standard
            defaults.set(newValue.retention.rawValue, forKey: retentionKey)
            defaults.set(newValue.discardRawAfterProcessing, forKey: discardRawKey)
        }
    }
}

/// 설정 화면의 오디오 보관 섹션을 움직이는 상태.
@MainActor
@Observable
public final class AudioStorageModel {
    /// 보관 기간. 바꾸면 바로 저장되고 다음 처리부터 적용된다.
    public var retention: AudioRetention {
        didSet {
            guard retention != oldValue else { return }
            AudioRetentionStore.policy = AudioRetentionPolicy(
                retention: retention,
                discardRawAfterProcessing: discardRawAfterProcessing
            )
        }
    }

    /// 회의록 생성 후 원본 트랙 정리 여부. 합성본은 그대로 남으므로 재생·재처리에는 영향이 없다.
    public var discardRawAfterProcessing: Bool {
        didSet {
            guard discardRawAfterProcessing != oldValue else { return }
            AudioRetentionStore.policy = AudioRetentionPolicy(
                retention: retention,
                discardRawAfterProcessing: discardRawAfterProcessing
            )
        }
    }

    public private(set) var trackCount: Int = 0
    public private(set) var bytes: Int64 = 0
    /// 디스크에 실제로 있는 오디오. 기록이 없는 잔여 파일까지 포함한다.
    public private(set) var diskUsage: AudioRetentionService.DiskUsage = .empty
    public private(set) var statusMessage: String?

    private let repository: MeetingRepository
    private let service: AudioRetentionService

    public init(repository: MeetingRepository) {
        self.repository = repository
        service = AudioRetentionService(repository: repository)
        let policy = AudioRetentionStore.policy
        retention = policy.retention
        discardRawAfterProcessing = policy.discardRawAfterProcessing
        refresh()
    }

    public var usageText: String {
        guard diskUsage.fileCount > 0 else { return "저장된 오디오 없음" }
        return "\(ByteFormat.short(diskUsage.bytes)) · 파일 \(diskUsage.fileCount)개"
    }

    /// 기록이 없어 자동 정리가 닿지 않는 파일 안내. 없으면 nil.
    public var untrackedText: String? {
        guard diskUsage.untrackedFileCount > 0 else { return nil }
        return "이 중 \(ByteFormat.short(diskUsage.untrackedBytes))(파일 \(diskUsage.untrackedFileCount)개)는 회의 기록과 연결되어 있지 않아 자동 정리 대상이 아닙니다. Finder에서 직접 지워야 합니다."
    }

    public func refresh() {
        do {
            let usage = try repository.audioStorageUsage()
            trackCount = usage.trackCount
            bytes = usage.bytes
            diskUsage = try service.diskUsage()
        } catch {
            statusMessage = "사용량을 읽지 못했습니다: \(error.localizedDescription)"
        }
    }

    /// 앱을 켤 때 조용히 정리한다. 지운 게 없으면 아무 메시지도 남기지 않는다.
    public func sweepAtLaunch(log: (@Sendable (String) -> Void)? = nil) {
        do {
            let outcome = try service.sweep(
                policy: AudioRetentionPolicy(
                    retention: retention,
                    discardRawAfterProcessing: discardRawAfterProcessing
                )
            )
            if outcome.trashedFileCount > 0 {
                log?("보관 기간이 지난 오디오 \(outcome.trashedFileCount)개를 정리했습니다 (\(ByteFormat.short(outcome.freedBytes))).")
            }
            refresh()
        } catch {
            log?("오디오 정리 실패: \(error.localizedDescription)")
        }
    }

    /// 보관 기간이 지난 오디오를 지금 정리한다.
    public func sweepNow() {
        do {
            let outcome = try service.sweep(
                policy: AudioRetentionPolicy(
                    retention: retention,
                    discardRawAfterProcessing: discardRawAfterProcessing
                )
            )
            statusMessage = outcome.trashedFileCount == 0
                ? "정리할 오디오가 없습니다."
                : "회의 \(outcome.meetingCount)건의 오디오 \(outcome.trashedFileCount)개를 휴지통으로 옮겼습니다 (\(ByteFormat.short(outcome.freedBytes)))."
            refresh()
        } catch {
            statusMessage = "정리에 실패했습니다: \(error.localizedDescription)"
        }
    }
}
