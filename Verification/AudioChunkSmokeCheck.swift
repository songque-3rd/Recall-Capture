import AVFoundation
import CaptureCore
import Foundation

@main
enum AudioChunkSmokeCheck {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw AudioChunkSmokeError.missingOutputDirectory
        }

        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let sessionID = UUID()
        let paths = RecordingWorkspacePaths(root: root, sessionID: sessionID)
        try paths.createDirectories(tracks: [.microphone])

        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 1
        ) else {
            throw AudioChunkSmokeError.invalidFormat
        }

        let writer = ChunkedAudioWriter(
            paths: paths,
            track: .microphone,
            chunkDurationSeconds: 2
        )
        var chunks: [AudioChunkDescriptor] = []
        for second in 0..<3 {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: 48_000
            ) else {
                throw AudioChunkSmokeError.cannotAllocateBuffer
            }
            buffer.frameLength = 48_000
            if let channel = buffer.floatChannelData?[0] {
                channel.initialize(repeating: 0, count: 48_000)
            }
            if let completed = try writer.append(
                buffer,
                sessionTimestampMilliseconds: Int64(second * 1_000)
            ) {
                chunks.append(completed)
            }
        }
        if let completed = try writer.finish() {
            chunks.append(completed)
        }

        guard chunks.count == 2,
              chunks.map(\.durationMilliseconds) == [2_000, 1_000],
              chunks.allSatisfy({ $0.byteCount > 0 }) else {
            throw AudioChunkSmokeError.invalidChunks(chunks)
        }

        let trackDirectory = paths.trackDirectory(.microphone)
        let files = try FileManager.default.contentsOfDirectory(
            at: trackDirectory,
            includingPropertiesForKeys: nil
        )
        guard files.filter({ $0.pathExtension == "caf" }).count == 2,
              files.allSatisfy({ !$0.lastPathComponent.contains(".partial.") }) else {
            throw AudioChunkSmokeError.partialFileRemained(files)
        }

        // A missing span must not shift all later words and speaker boundaries.
        let gapPaths = RecordingWorkspacePaths(root: root, sessionID: UUID())
        try gapPaths.createDirectories(tracks: [.microphone])
        let gapWriter = ChunkedAudioWriter(paths: gapPaths, track: .microphone, chunkDurationSeconds: 60)
        let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        silence.frameLength = 48_000
        silence.floatChannelData![0].initialize(repeating: 0, count: 48_000)
        guard try gapWriter.append(silence, sessionTimestampMilliseconds: 0) == nil,
              let first = try gapWriter.append(silence, sessionTimestampMilliseconds: 10_000),
              let second = try gapWriter.finish(),
              first.startedAtMilliseconds == 0, first.durationMilliseconds == 1_000,
              second.startedAtMilliseconds == 10_000, second.durationMilliseconds == 1_000,
              !AudioInputMeter.measure(silence).hasSound else {
            throw AudioChunkSmokeError.invalidMeterOrTiming
        }
        // Verify both planar and interleaved stereo, with sound only on channel 2.
        for common: AVAudioCommonFormat in [.pcmFormatFloat32, .pcmFormatFloat64, .pcmFormatInt16, .pcmFormatInt32] {
            for interleaved in [false, true] {
                let stereo = AVAudioFormat(commonFormat: common, sampleRate: 48_000,
                                           channels: 2, interleaved: interleaved)!
                let buffer = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 4)!
                buffer.frameLength = 4
                let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                for channel in 0..<2 {
                    for frame in 0..<4 {
                        let data = list[interleaved ? 0 : channel].mData!
                        let index = frame * Int(buffer.stride) + (interleaved ? channel : 0)
                        switch common {
                        case .pcmFormatFloat32: data.assumingMemoryBound(to: Float.self)[index] = channel == 0 ? 0 : 0.5
                        case .pcmFormatFloat64: data.assumingMemoryBound(to: Double.self)[index] = channel == 0 ? 0 : 0.5
                        case .pcmFormatInt16: data.assumingMemoryBound(to: Int16.self)[index] = channel == 0 ? 0 : 16_384
                        case .pcmFormatInt32: data.assumingMemoryBound(to: Int32.self)[index] = channel == 0 ? 0 : 1_073_741_824
                        default: break
                        }
                    }
                }
                let measured = AudioInputMeter.measure(buffer)
                guard abs(measured.rms - sqrt(0.125)) < 0.0001,
                      measured.peak == 0.5, measured.hasSound else {
                    throw AudioChunkSmokeError.invalidMeterOrTiming
                }
            }
        }

        print("audio-chunk-smoke-check: passed")
        print(paths.directory.path)
    }
}

enum AudioChunkSmokeError: Error {
    case missingOutputDirectory
    case invalidFormat
    case cannotAllocateBuffer
    case invalidChunks([AudioChunkDescriptor])
    case partialFileRemained([URL])
    case invalidMeterOrTiming
}
