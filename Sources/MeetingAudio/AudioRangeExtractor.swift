import AVFoundation
import Foundation
import MeetingCore

public enum AudioRangeExtractorError: Error, LocalizedError, Sendable {
    case invalidRange
    case sourceUnreadable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRange:
            "다시 전사할 오디오 구간이 올바르지 않습니다."
        case let .sourceUnreadable(message):
            "선택 구간 오디오를 만들지 못했습니다: \(message)"
        }
    }
}

/// 원본에서 선택 구간만 잘라 새 파일로 쓴다. 원본은 그대로 둔다.
public enum AudioRangeExtractor {
    /// - Parameters:
    ///   - source: 회의 오디오
    ///   - range: 회의 시각 기준 구간
    ///   - output: 잘라 낸 파일 경로
    /// - Returns: 실제로 잘라 낸 구간(오디오 길이에 맞게 잘림)과 파일 정보
    public static func extract(
        from source: URL,
        range: TimeRange,
        to output: URL
    ) throws -> (range: TimeRange, info: AudioFileInfo) {
        let sourceFile: AVAudioFile
        do {
            sourceFile = try AVAudioFile(forReading: source)
        } catch {
            throw AudioRangeExtractorError.sourceUnreadable(error.localizedDescription)
        }

        let format = sourceFile.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate > 0 else {
            throw AudioRangeExtractorError.sourceUnreadable("샘플레이트가 0입니다.")
        }

        let totalFrames = sourceFile.length
        let duration = Double(totalFrames) / sampleRate
        let clamped = range.clamped(toDuration: duration)
        guard clamped.isValid else {
            throw AudioRangeExtractorError.invalidRange
        }

        let startFrame = AVAudioFramePosition((clamped.start * sampleRate).rounded(.down))
        let endFrame = min(totalFrames, AVAudioFramePosition((clamped.end * sampleRate).rounded(.up)))
        let framesToCopy = endFrame - startFrame
        guard framesToCopy > 0 else {
            throw AudioRangeExtractorError.invalidRange
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: output.path) {
            try fileManager.removeItem(at: output)
        }

        sourceFile.framePosition = max(0, startFrame)
        let outputFile: AVAudioFile
        do {
            outputFile = try AVAudioFile(forWriting: output, settings: format.settings)
        } catch {
            throw AudioRangeExtractorError.sourceUnreadable(error.localizedDescription)
        }

        var remaining = AVAudioFrameCount(framesToCopy)
        let chunk = AVAudioFrameCount(min(Int(sampleRate) * 30, Int(remaining)))
        while remaining > 0 {
            let thisRead = min(chunk, remaining)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: thisRead) else {
                throw AudioRangeExtractorError.sourceUnreadable("오디오 버퍼를 만들지 못했습니다.")
            }
            do {
                try sourceFile.read(into: buffer, frameCount: thisRead)
                try outputFile.write(from: buffer)
            } catch {
                throw AudioRangeExtractorError.sourceUnreadable(error.localizedDescription)
            }
            remaining -= buffer.frameLength
            if buffer.frameLength == 0 {
                break
            }
        }

        let info = try AudioFileInspector.inspect(url: output)
        return (clamped, info)
    }
}
