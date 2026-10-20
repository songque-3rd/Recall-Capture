import AVFoundation
import CaptureCore
import Foundation

struct SpeakerDiarizationResult: Sendable {
    let timelines: [AudioTrack: SpeakerTimeline]
    let warnings: [String]

    static let empty = SpeakerDiarizationResult(timelines: [:], warnings: [])
}

private enum SpeakerDiarizationEngineError: LocalizedError {
    case missingAssets
    case invalidAudio(String)
    case noAudio(AudioTrack)
    case launchFailed(String)
    case processFailed(Int32, String)
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .missingAssets:
            "Nemotron話者分離ランタイムまたはモデルが見つかりません。"
        case let .invalidAudio(path):
            "話者分離用音声を読み取れません: \(path)"
        case let .noAudio(track):
            "\(track.rawValue)トラックに話者分離用音声がありません。"
        case let .launchFailed(reason):
            "Nemotron話者分離を起動できません: \(reason)"
        case let .processFailed(status, detail):
            "Nemotron話者分離が終了コード\(status)で失敗しました。\(detail)"
        case .invalidOutput:
            "Nemotron話者分離のRTTM出力を検証できませんでした。"
        }
    }
}

final class SpeakerDiarizationEngine: @unchecked Sendable {
    private let fileManager: FileManager
    private let environment: [String: String]
    private let bundle: Bundle

    init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) {
        self.fileManager = fileManager
        self.environment = environment
        self.bundle = bundle
    }

    func diarize(
        manifest: RecordingManifest,
        workspace: RecordingWorkspacePaths
    ) async -> SpeakerDiarizationResult {
        await Task.detached(priority: .userInitiated) { [self] in
            diarizeSynchronously(manifest: manifest, workspace: workspace)
        }.value
    }

    private func diarizeSynchronously(
        manifest: RecordingManifest,
        workspace: RecordingWorkspacePaths
    ) -> SpeakerDiarizationResult {
        let tracks = targetTracks(for: manifest).filter { track in
            manifest.chunks.contains { $0.track == track }
        }
        guard !tracks.isEmpty else { return .empty }

        guard let executableURL = executableURL(),
              let modelURL = modelURL(),
              fileManager.isExecutableFile(atPath: executableURL.path),
              fileManager.fileExists(atPath: modelURL.path) else {
            return SpeakerDiarizationResult(
                timelines: [:],
                warnings: ["Nemotron話者分離を利用できないため、対象話者は unknown として記録しました。"]
            )
        }

        let temporaryDirectory = workspace.directory.appendingPathComponent(
            ".diarization-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
        } catch {
            return SpeakerDiarizationResult(
                timelines: [:],
                warnings: ["話者分離用の一時領域を作成できないため、対象話者は unknown として記録しました。"]
            )
        }
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        var timelines: [AudioTrack: SpeakerTimeline] = [:]
        var warnings: [String] = []
        for track in tracks {
            do {
                let wavURL = temporaryDirectory.appendingPathComponent("\(track.rawValue).wav")
                try assembleWAV(
                    chunks: manifest.chunks.filter { $0.track == track },
                    workspace: workspace,
                    outputURL: wavURL,
                    track: track
                )
                let rttmURL = temporaryDirectory.appendingPathComponent("\(track.rawValue).rttm")
                let timeline = try runDiarization(
                    executableURL: executableURL,
                    modelURL: modelURL,
                    inputURL: wavURL,
                    outputURL: rttmURL,
                    temporaryDirectory: temporaryDirectory
                )
                if timeline.segments.isEmpty {
                    warnings.append("\(track.rawValue)トラックから話者を特定できなかったため、該当話者は unknown として記録しました。")
                } else {
                    timelines[track] = timeline
                }
            } catch {
                warnings.append("\(track.rawValue)トラックの話者分離に失敗したため、該当話者は unknown として記録しました（\(error.localizedDescription)）。")
            }
        }
        return SpeakerDiarizationResult(timelines: timelines, warnings: warnings)
    }

    private func targetTracks(for manifest: RecordingManifest) -> [AudioTrack] {
        manifest.tracks
    }

    private func executableURL() -> URL? {
        if bundle.object(forInfoDictionaryKey: "RecallCaptureDistribution") as? Bool != true,
           let path = environment["RECALL_CAPTURE_NEMO_SPEECH_PATH"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return bundle.resourceURL?
            .appendingPathComponent("NemotronDiarization/runtime/bin/nemo-speech")
    }

    private func modelURL() -> URL? {
        if bundle.object(forInfoDictionaryKey: "RecallCaptureDistribution") as? Bool != true,
           let path = environment["RECALL_CAPTURE_DIARIZATION_MODEL_PATH"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return bundle.resourceURL?
            .appendingPathComponent("NemotronDiarization/models/Nemotron-3-Diarization.q8_0.gguf")
    }

    private func assembleWAV(
        chunks: [AudioChunkDescriptor],
        workspace: RecordingWorkspacePaths,
        outputURL: URL,
        track: AudioTrack
    ) throws {
        let format = try requiredAudioFormat()
        let output = try AVAudioFile(
            forWriting: outputURL,
            settings: format.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        var outputFrame: AVAudioFramePosition = 0
        let sampleRate = format.sampleRate

        for chunk in chunks.sorted(by: chunkOrder) {
            let inputURL = workspace.directory.appendingPathComponent(chunk.relativePath)
            guard fileManager.fileExists(atPath: inputURL.path) else {
                throw SpeakerDiarizationEngineError.invalidAudio(chunk.relativePath)
            }
            let input = try AVAudioFile(
                forReading: inputURL,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
            guard input.processingFormat.channelCount == 1,
                  abs(input.processingFormat.sampleRate - sampleRate) < 0.5 else {
                throw SpeakerDiarizationEngineError.invalidAudio(chunk.relativePath)
            }

            let chunkStart = AVAudioFramePosition(
                (Double(max(0, chunk.startedAtMilliseconds)) * sampleRate / 1_000).rounded()
            )
            if chunkStart > outputFrame {
                try writeSilence(frames: chunkStart - outputFrame, format: format, to: output)
                outputFrame = chunkStart
            }

            let skippedFrames = max(0, outputFrame - chunkStart)
            guard skippedFrames < input.length else { continue }
            input.framePosition = skippedFrames
            while input.framePosition < input.length {
                let available = min(input.length - input.framePosition, 16_384)
                let frameCount = AVAudioFrameCount(available)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                    throw SpeakerDiarizationEngineError.invalidAudio(chunk.relativePath)
                }
                try input.read(into: buffer, frameCount: frameCount)
                guard buffer.frameLength > 0 else { break }
                try output.write(from: buffer)
                outputFrame += AVAudioFramePosition(buffer.frameLength)
            }
        }

        guard outputFrame > 0 else {
            throw SpeakerDiarizationEngineError.noAudio(track)
        }
    }

    private func requiredAudioFormat() throws -> AVAudioFormat {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) else {
            throw SpeakerDiarizationEngineError.invalidAudio("16 kHz PCM形式を作成できません")
        }
        return format
    }

    private func writeSilence(
        frames: AVAudioFramePosition,
        format: AVAudioFormat,
        to output: AVAudioFile
    ) throws {
        var remaining = frames
        while remaining > 0 {
            let count = AVAudioFrameCount(min(remaining, 16_384))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
                  let samples = buffer.int16ChannelData else {
                throw SpeakerDiarizationEngineError.invalidAudio("無音区間")
            }
            samples[0].initialize(repeating: 0, count: Int(count))
            buffer.frameLength = count
            try output.write(from: buffer)
            remaining -= AVAudioFramePosition(count)
        }
    }

    private func runDiarization(
        executableURL: URL,
        modelURL: URL,
        inputURL: URL,
        outputURL: URL,
        temporaryDirectory: URL
    ) throws -> SpeakerTimeline {
        let logURL = temporaryDirectory.appendingPathComponent("\(inputURL.deletingPathExtension().lastPathComponent).log")
        guard fileManager.createFile(atPath: logURL.path, contents: nil),
              let logHandle = try? FileHandle(forWritingTo: logURL) else {
            throw SpeakerDiarizationEngineError.launchFailed("実行ログを作成できません")
        }
        defer { try? logHandle.close() }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "diarize", inputURL.path,
            "--model", modelURL.path,
            "--device", "cpu",
            "--preset", "v3-offline",
            "--format", "rttm",
            "--output", outputURL.path,
        ]
        process.standardOutput = logHandle
        process.standardError = logHandle
        do {
            try process.run()
        } catch {
            throw SpeakerDiarizationEngineError.launchFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        try? logHandle.synchronize()

        guard process.terminationStatus == 0 else {
            let detail = (try? String(contentsOf: logURL, encoding: .utf8))
                .map { String($0.suffix(800)) }
                ?? ""
            throw SpeakerDiarizationEngineError.processFailed(process.terminationStatus, detail)
        }
        guard let text = try? String(contentsOf: outputURL, encoding: .utf8) else {
            throw SpeakerDiarizationEngineError.invalidOutput
        }
        return RTTMParser.parse(text)
    }

    private func chunkOrder(_ lhs: AudioChunkDescriptor, _ rhs: AudioChunkDescriptor) -> Bool {
        if lhs.startedAtMilliseconds == rhs.startedAtMilliseconds {
            return lhs.index < rhs.index
        }
        return lhs.startedAtMilliseconds < rhs.startedAtMilliseconds
    }
}
