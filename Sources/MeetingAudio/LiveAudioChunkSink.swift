import AVFoundation
import Foundation
import MeetingCore

/// 탭 콜백에서 PCM을 받아 닫힌 CAF 조각으로 나눈다.
///
/// AAC 본 녹음은 파일이 열려 있어 읽기 어렵다. 자막용 조각은 길이가 차면 닫아서
/// Whisper가 바로 읽을 수 있게 한다. 콜백은 실시간 스레드이므로 락만 짧게 쓴다.
final class LiveAudioChunkSink: @unchecked Sendable {
    private let directory: URL
    private let format: AVAudioFormat
    private let chunkFrames: AVAudioFrameCount
    private let minimumFinishDuration: TimeInterval
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var currentURL: URL?
    private var frames: AVAudioFrameCount = 0
    private var chunkIndex = 0
    private var startOffset: TimeInterval = 0
    private var ready: [LiveAudioChunk] = []

    init(
        directory: URL,
        format: AVAudioFormat,
        chunkDuration: TimeInterval = 12,
        minimumFinishDuration: TimeInterval = 1
    ) {
        self.directory = directory
        self.format = format
        chunkFrames = AVAudioFrameCount(max(1, format.sampleRate * chunkDuration))
        self.minimumFinishDuration = minimumFinishDuration
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard buffer.frameLength > 0 else { return }
        do {
            try ensureFile()
            try file?.write(from: buffer)
            frames += buffer.frameLength
            if frames >= chunkFrames {
                rotate()
            }
        } catch {
            file = nil
            currentURL = nil
            frames = 0
        }
    }

    func takeReady() -> [LiveAudioChunk] {
        lock.lock()
        defer { lock.unlock() }
        let chunks = ready
        ready.removeAll()
        return chunks
    }

    /// 녹음이 끝나면 남은 조각을 닫아 돌려준다. 너무 짧은 꼬리는 버린다.
    func finish() -> [LiveAudioChunk] {
        lock.lock()
        defer { lock.unlock() }
        if frames > 0 {
            let duration = Double(frames) / format.sampleRate
            if duration >= minimumFinishDuration {
                rotate()
            } else {
                discardCurrent()
            }
        }
        let chunks = ready
        ready.removeAll()
        return chunks
    }

    private func ensureFile() throws {
        guard file == nil else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(String(format: "chunk-%04d.caf", chunkIndex))
        chunkIndex += 1
        file = try AVAudioFile(forWriting: url, settings: format.settings)
        currentURL = url
    }

    private func rotate() {
        guard let url = currentURL, frames > 0 else {
            discardCurrent()
            return
        }
        let duration = Double(frames) / format.sampleRate
        file = nil
        ready.append(LiveAudioChunk(url: url, startOffset: startOffset, duration: duration))
        startOffset += duration
        currentURL = nil
        frames = 0
    }

    private func discardCurrent() {
        file = nil
        if let url = currentURL {
            try? FileManager.default.removeItem(at: url)
        }
        currentURL = nil
        frames = 0
    }
}
