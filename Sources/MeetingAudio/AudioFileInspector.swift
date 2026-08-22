import AVFoundation
import Foundation
import MeetingCore

public struct AudioFileInfo: Hashable, Sendable {
    public var url: URL
    public var duration: TimeInterval
    public var sampleRate: Double
    public var channelCount: Int
    public var byteSize: Int64

    public init(url: URL, duration: TimeInterval, sampleRate: Double, channelCount: Int, byteSize: Int64) {
        self.url = url
        self.duration = duration
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.byteSize = byteSize
    }
}

/// 오디오 파일 메타데이터 조회. 손상된 파일은 여기서 걸러 재처리 루프에 들어가지 않게 한다(§15).
public enum AudioFileInspector {
    public static func inspect(url: URL, fileManager: FileManager = .default) throws -> AudioFileInfo {
        guard fileManager.fileExists(atPath: url.path) else {
            throw TranscriptionEngineError.audioFileMissing(url)
        }
        let byteSize = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

        // AVAudioFile은 손상 파일에서 즉시 오류를 던져 검증에 적합하다.
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let duration = format.sampleRate > 0 ? Double(file.length) / format.sampleRate : 0
            guard duration > 0 else {
                throw TranscriptionEngineError.audioFileUnreadable(url, underlying: "길이가 0인 오디오")
            }
            return AudioFileInfo(
                url: url,
                duration: duration,
                sampleRate: format.sampleRate,
                channelCount: Int(format.channelCount),
                byteSize: byteSize ?? 0
            )
        } catch let error as TranscriptionEngineError {
            throw error
        } catch {
            throw TranscriptionEngineError.audioFileUnreadable(url, underlying: error.localizedDescription)
        }
    }
}
