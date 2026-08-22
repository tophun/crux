import Foundation
#if canImport(Darwin)
    import Darwin
#endif

/// 처리 시간과 메모리 사용량 기록. 16GB 제약(§12) 준수를 관측 가능하게 만든다.
public struct StageMetric: Hashable, Sendable, Codable {
    public var stage: String
    public var duration: TimeInterval
    /// 단계 종료 시점의 프로세스 실제 메모리(바이트)
    public var residentBytes: UInt64
    /// 프로세스 최대 실제 메모리(바이트)
    public var peakResidentBytes: UInt64
    public var note: String?

    public init(
        stage: String,
        duration: TimeInterval,
        residentBytes: UInt64,
        peakResidentBytes: UInt64,
        note: String? = nil
    ) {
        self.stage = stage
        self.duration = duration
        self.residentBytes = residentBytes
        self.peakResidentBytes = peakResidentBytes
        self.note = note
    }

    public var description: String {
        let mb = { (b: UInt64) in String(format: "%.0fMB", Double(b) / 1_048_576) }
        return "[\(stage)] \(String(format: "%.2fs", duration)) rss=\(mb(residentBytes)) peak=\(mb(peakResidentBytes))"
            + (note.map { " \($0)" } ?? "")
    }
}

/// 프로세스 메모리 측정. 테스트 가능한 순수 인터페이스로 감싼다.
public enum MemoryProbe {
    public static func residentBytes() -> UInt64 {
        #if canImport(Darwin)
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
                }
            }
            return result == KERN_SUCCESS ? info.resident_size : 0
        #else
            return 0
        #endif
    }

    public static func peakResidentBytes() -> UInt64 {
        #if canImport(Darwin)
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
                }
            }
            return result == KERN_SUCCESS ? info.resident_size_max : 0
        #else
            return 0
        #endif
    }
}

/// 단계별 시간·메모리 로그 수집기.
public actor StageMetricsRecorder {
    private var metrics: [StageMetric] = []
    private let sink: (@Sendable (StageMetric) -> Void)?

    public init(sink: (@Sendable (StageMetric) -> Void)? = nil) {
        self.sink = sink
    }

    public func record<T: Sendable>(_ stage: String, note: String? = nil, _ body: sending () async throws -> T) async throws -> T {
        let start = Date()
        let value = try await body()
        let metric = StageMetric(
            stage: stage,
            duration: Date().timeIntervalSince(start),
            residentBytes: MemoryProbe.residentBytes(),
            peakResidentBytes: MemoryProbe.peakResidentBytes(),
            note: note
        )
        metrics.append(metric)
        sink?(metric)
        return value
    }

    public func all() -> [StageMetric] {
        metrics
    }
}
