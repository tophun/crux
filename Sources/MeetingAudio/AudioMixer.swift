import AVFoundation
import Foundation
import MeetingCore

/// 마이크와 시스템 오디오를 하나의 파일로 합친다.
///
/// 원본 트랙은 지우지 않고 `mixed/meeting.m4a`를 따로 만든다.
/// 전사에는 mixed를 우선 사용하고, 화자 구분·음질 분석을 위해 원본을 로컬에 보존한다(§5).
public enum AudioMixer {
    /// - Parameters:
    ///   - inputs: 합칠 오디오 파일 (없는 파일은 건너뛴다)
    ///   - output: 결과 파일 경로 (m4a)
    public static func mix(inputs: [URL], output: URL) async throws -> AudioFileInfo {
        let existing = inputs.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { throw CaptureError.mixFailed("합칠 오디오 파일이 없습니다.") }

        // 하나만 있으면 그대로 복사한다.
        if existing.count == 1 {
            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: output.path) {
                try FileManager.default.removeItem(at: output)
            }
            try FileManager.default.copyItem(at: existing[0], to: output)
            return try AudioFileInspector.inspect(url: output)
        }

        let composition = AVMutableComposition()
        for url in existing {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let sourceTrack = tracks.first else { continue }
            guard let target = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }
            let duration = try await asset.load(.duration)
            try target.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: sourceTrack,
                at: .zero
            )
        }

        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }

        // 내보내기 프리셋은 비트레이트를 지정할 수 없어 파일이 불필요하게 커진다.
        // 직접 읽어 16kHz 모노 32kbps로 다시 인코딩한다.
        try await encode(composition: composition, to: output)
        return try AudioFileInspector.inspect(url: output)
    }

    /// 합성 결과를 16kHz 모노 32kbps AAC로 인코딩한다.
    ///
    /// `AVAssetExportSession` 프리셋은 비트레이트를 지정할 수 없어 결과 파일이 커진다.
    /// 전사 품질에 필요한 대역만 남기려고 직접 읽고 쓴다(§5 저장 정책).
    static func encode(composition: AVMutableComposition, to output: URL) async throws {
        let audioTracks = composition.tracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { throw CaptureError.mixFailed("오디오 트랙이 없습니다.") }

        let reader = try AVAssetReader(asset: composition)
        let readerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let mixOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: readerSettings)
        guard reader.canAdd(mixOutput) else { throw CaptureError.mixFailed("믹스 출력을 만들 수 없습니다.") }
        reader.add(mixOutput)

        let writer = try AVAssetWriter(outputURL: output, fileType: .m4a)
        let writerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: writerSettings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw CaptureError.mixFailed("오디오 입력을 만들 수 없습니다.") }
        writer.add(input)

        guard reader.startReading() else {
            throw CaptureError.mixFailed(reader.error?.localizedDescription ?? "읽기를 시작할 수 없습니다.")
        }
        guard writer.startWriting() else {
            throw CaptureError.mixFailed(writer.error?.localizedDescription ?? "쓰기를 시작할 수 없습니다.")
        }
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "crux.audio-mixer")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let finished = Locked(false)
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard reader.status == .reading, let sample = mixOutput.copyNextSampleBuffer() else {
                        if finished.set() {
                            input.markAsFinished()
                            continuation.resume()
                        }
                        return
                    }
                    if !input.append(sample) {
                        if finished.set() {
                            input.markAsFinished()
                            continuation.resume()
                        }
                        return
                    }
                }
            }
        }

        await writer.finishWriting()
        if writer.status == .failed {
            throw CaptureError.mixFailed(writer.error?.localizedDescription ?? "인코딩에 실패했습니다.")
        }
    }
}

/// 콜백이 여러 번 들어와도 continuation을 한 번만 재개하기 위한 잠금 상자.
private final class Locked: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ value: Bool) {
        self.value = value
    }

    /// 아직 표시되지 않았으면 표시하고 true를 돌려준다.
    func set() -> Bool {
        lock.withLock {
            if value {
                return false
            }
            value = true
            return true
        }
    }
}
