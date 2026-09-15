@preconcurrency import AVFoundation
import CaptureCore
import CoreMedia
import Foundation

enum AudioCaptureError: LocalizedError {
    case missingAudioFormat
    case cannotAllocateBuffer
    case cannotCreateStorageFormat
    case cannotCreateAudioConverter
    case conversionFailed(String)
    case audioWriteFailed(String)
    case copyFailed(OSStatus)
    case invalidSampleRate
    case noInputDevice
    case cannotAddInput
    case cannotAddOutput
    case meetWindowUnavailable
    case permissionDenied(String)
    case alreadyRecording
    case notRecording

    var errorDescription: String? {
        switch self {
        case .missingAudioFormat: "音声フォーマットを取得できませんでした。"
        case .cannotAllocateBuffer: "音声バッファを確保できませんでした。"
        case .cannotCreateStorageFormat: "保存用の音声フォーマットを作成できませんでした。"
        case .cannotCreateAudioConverter: "保存用の音声変換器を作成できませんでした。"
        case let .conversionFailed(message): "音声の保存形式への変換に失敗しました（\(message)）。"
        case let .audioWriteFailed(message): "音声チャンクへの書き込みに失敗しました（\(message)）。"
        case let .copyFailed(status): "音声データの変換に失敗しました（\(status)）。"
        case .invalidSampleRate: "音声のサンプルレートが不正です。"
        case .noInputDevice: "利用可能なマイクが見つかりません。"
        case .cannotAddInput: "選択したマイクを録音セッションに追加できません。"
        case .cannotAddOutput: "音声出力を録音セッションに追加できません。"
        case .meetWindowUnavailable: "選択した会議ウインドウが見つかりません。"
        case let .permissionDenied(name): "\(name)の権限が許可されていません。"
        case .alreadyRecording: "別の録音が進行中です。"
        case .notRecording: "録音は開始されていません。"
        }
    }
}

enum SampleBufferAudioConverter {
    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw AudioCaptureError.missingAudioFormat
        }
        let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AudioCaptureError.cannotAllocateBuffer
        }
        buffer.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else {
            throw AudioCaptureError.copyFailed(status)
        }
        return buffer
    }

    static func presentationSeconds(of sampleBuffer: CMSampleBuffer) -> Double? {
        let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        return seconds.isFinite ? seconds : nil
    }
}

final class ChunkedAudioWriter {
    private let paths: RecordingWorkspacePaths
    private let track: AudioTrack
    private let chunkDurationSeconds: Double
    private let fileManager: FileManager

    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var currentPartialURL: URL?
    private var currentChunkStartMilliseconds: Int64 = 0
    private var currentFrameCount: AVAudioFramePosition = 0
    private var nextIndex = 1

    init(
        paths: RecordingWorkspacePaths,
        track: AudioTrack,
        chunkDurationSeconds: Int,
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.track = track
        self.chunkDurationSeconds = Double(chunkDurationSeconds)
        self.fileManager = fileManager
    }

    func append(
        _ buffer: AVAudioPCMBuffer,
        sessionTimestampMilliseconds: Int64
    ) throws -> AudioChunkDescriptor? {
        guard buffer.format.sampleRate > 0 else {
            throw AudioCaptureError.invalidSampleRate
        }

        var completed: AudioChunkDescriptor?
        if let inputFormat,
           (!Self.formatsMatch(inputFormat, buffer.format)
            || durationSeconds + Double(buffer.frameLength) / buffer.format.sampleRate > chunkDurationSeconds),
           currentFrameCount > 0 {
            completed = try finalizeCurrentChunk()
        }

        if file == nil {
            try openChunk(format: buffer.format, startMilliseconds: sessionTimestampMilliseconds)
        }
        try writeConverted(buffer)
        return completed
    }

    func finish() throws -> AudioChunkDescriptor? {
        guard file != nil else { return nil }
        return try finalizeCurrentChunk()
    }

    private var durationSeconds: Double {
        Double(currentFrameCount) / 16_000
    }

    private func openChunk(format: AVAudioFormat, startMilliseconds: Int64) throws {
        let partialURL = paths.partialChunkURL(track: track, index: nextIndex)
        guard let storageFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) else {
            throw AudioCaptureError.cannotCreateStorageFormat
        }
        file = try AVAudioFile(
            forWriting: partialURL,
            settings: storageFormat.settings,
            commonFormat: storageFormat.commonFormat,
            interleaved: storageFormat.isInterleaved
        )
        guard let audioConverter = AVAudioConverter(from: format, to: storageFormat) else {
            file = nil
            throw AudioCaptureError.cannotCreateAudioConverter
        }
        converter = audioConverter
        inputFormat = format
        currentPartialURL = partialURL
        currentChunkStartMilliseconds = max(0, startMilliseconds)
        currentFrameCount = 0
    }

    private func writeConverted(_ buffer: AVAudioPCMBuffer) throws {
        guard let file, let converter else {
            throw AudioCaptureError.cannotCreateAudioConverter
        }
        let outputFormat = converter.outputFormat
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(
            max(Double(buffer.frameLength), ceil(Double(buffer.frameLength) * ratio) + 32)
        )
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else {
            throw AudioCaptureError.cannotAllocateBuffer
        }
        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: convertedBuffer, error: &conversionError) {
            _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else {
            throw AudioCaptureError.conversionFailed(
                conversionError?.localizedDescription ?? "unknown error"
            )
        }
        try writeToCurrentFile(convertedBuffer, file: file)
    }

    private func finalizeCurrentChunk() throws -> AudioChunkDescriptor? {
        guard let partialURL = currentPartialURL, inputFormat != nil else { return nil }
        try flushConverter()
        let durationMilliseconds = Int64((durationSeconds * 1_000).rounded())
        file = nil

        guard currentFrameCount > 0 else {
            try? fileManager.removeItem(at: partialURL)
            resetCurrentChunk()
            return nil
        }

        let finalURL = paths.completedChunkURL(track: track, index: nextIndex)
        try fileManager.moveItem(at: partialURL, to: finalURL)
        let attributes = try fileManager.attributesOfItem(atPath: finalURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let descriptor = AudioChunkDescriptor(
            index: nextIndex,
            track: track,
            relativePath: paths.relativeCompletedChunkPath(track: track, index: nextIndex),
            startedAtMilliseconds: currentChunkStartMilliseconds,
            durationMilliseconds: durationMilliseconds,
            byteCount: byteCount
        )
        nextIndex += 1
        resetCurrentChunk()
        return descriptor
    }

    private func flushConverter() throws {
        guard let file, let converter else { return }
        while true {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: converter.outputFormat,
                frameCapacity: 1_024
            ) else {
                throw AudioCaptureError.cannotAllocateBuffer
            }
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) {
                _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            guard status != .error else {
                throw AudioCaptureError.conversionFailed(
                    conversionError?.localizedDescription ?? "unknown error"
                )
            }
            try writeToCurrentFile(outputBuffer, file: file)
            if status == .endOfStream || outputBuffer.frameLength == 0 {
                break
            }
        }
    }

    private func writeToCurrentFile(
        _ buffer: AVAudioPCMBuffer,
        file: AVAudioFile
    ) throws {
        guard buffer.frameLength > 0 else { return }
        do {
            try file.write(from: buffer)
        } catch {
            throw AudioCaptureError.audioWriteFailed(error.localizedDescription)
        }
        currentFrameCount += AVAudioFramePosition(buffer.frameLength)
    }

    private func resetCurrentChunk() {
        file = nil
        converter = nil
        inputFormat = nil
        currentPartialURL = nil
        currentFrameCount = 0
    }

    private static func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.commonFormat == rhs.commonFormat
            && lhs.isInterleaved == rhs.isInterleaved
    }
}
