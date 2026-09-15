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
}
