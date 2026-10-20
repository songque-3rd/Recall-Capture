import AVFoundation
import CaptureCore
import Foundation

@main
enum SpeakerDiarizationEngineCheck {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(description: message) }
    }

    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let workspace = RecordingWorkspacePaths(root: root, sessionID: UUID())
        try workspace.createDirectories(tracks: [.system, .microphone])
        var manifest = RecordingManifest(sessionID: UUID(), title: "分割音声の話者判別",
            captureMode: .meet, languageMode: .japanese, startedAt: Date(), tracks: [.system, .microphone])
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
            channels: 1, interleaved: true)!
        for track in manifest.tracks {
            for (index, start, value) in [(1, 1_000, 1_000), (2, 3_000, 2_000), (3, 3_500, 3_000)] {
                let relative = "audio/\(track.rawValue)/\(index).caf"
                let url = workspace.directory.appendingPathComponent(relative)
                try writeAudio(to: url, format: format, value: Int16(value))
                manifest.append(.init(index: index, track: track, relativePath: relative,
                    startedAtMilliseconds: Int64(start), durationMilliseconds: 1_000, byteCount: 1))
            }
        }

        // Inspect the exact audio and arguments handed to the external runtime.
        // This catches lost silence, duplicate overlap, and per-chunk speaker resets.
        let runner = root.appendingPathComponent("nemo-fixture.py")
        try #"""
        #!/usr/bin/python3
        import array, pathlib, sys, wave
        args = sys.argv[1:]
        assert args[0] == 'diarize'
        assert args[args.index('--device') + 1] == 'cpu'
        assert args[args.index('--preset') + 1] == 'v3-offline'
        assert args[args.index('--format') + 1] == 'rttm'
        with wave.open(args[1], 'rb') as audio:
            assert (audio.getnchannels(), audio.getframerate(), audio.getsampwidth()) == (1, 16000, 2)
            assert audio.getnframes() == 72000
            samples = array.array('h', audio.readframes(72000))
        for start, end, value in [(0,16000,0),(16000,32000,1000),(32000,48000,0),(48000,64000,2000),(64000,72000,3000)]:
            assert all(x == value for x in samples[start:end]), (start, end, value)
        with pathlib.Path(__file__).with_name('calls.txt').open('a') as audit:
            audit.write(pathlib.Path(args[1]).stem + '\n')
        pathlib.Path(args[args.index('--output') + 1]).write_text(
            'SPEAKER fixture 1 1.0 1.0 <NA> <NA> speaker_1 <NA> <NA>\n'
            'SPEAKER fixture 1 3.0 1.5 <NA> <NA> speaker_2 <NA> <NA>\n')
        """#.write(to: runner, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runner.path)
        let model = root.appendingPathComponent("model.gguf")
        try Data([0]).write(to: model)
        let environment = ["RECALL_CAPTURE_NEMO_SPEECH_PATH": runner.path,
            "RECALL_CAPTURE_DIARIZATION_MODEL_PATH": model.path]
        let result = await SpeakerDiarizationEngine(environment: environment).diarize(manifest: manifest, workspace: workspace)
        try check(result.warnings.isEmpty && result.timelines.count == 2, "Both tracks must be diarized: \(result.warnings)")
        for track in manifest.tracks {
            let timeline = result.timelines[track]!
            try check(timeline.speakerLabel(startMilliseconds: 1_100, endMilliseconds: 1_900) == "speaker_01", "First speaker timing lost")
            try check(timeline.speakerLabel(startMilliseconds: 3_100, endMilliseconds: 4_400) == "speaker_02", "Second speaker timing lost")
        }
        let calls = try String(contentsOf: root.appendingPathComponent("calls.txt"), encoding: .utf8)
        try check(calls.split(separator: "\n").count == 2, "Runtime must run once per complete track")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: workspace.directory.path)
        try check(!leftovers.contains { $0.hasPrefix(".diarization-") }, "Temporary audio not cleaned")
        let missing = await SpeakerDiarizationEngine(environment: ["RECALL_CAPTURE_NEMO_SPEECH_PATH": root.appendingPathComponent("absent").path,
            "RECALL_CAPTURE_DIARIZATION_MODEL_PATH": model.path]).diarize(manifest: manifest, workspace: workspace)
        try check(missing.timelines.isEmpty && !missing.warnings.isEmpty, "Missing assets must not invent speakers")
        // Public builds must ignore process-environment executable/model overrides.
        let bundleURL = root.appendingPathComponent("DistributionFixture.bundle")
        try FileManager.default.createDirectory(at: bundleURL.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "jp.recallcapture.distribution-fixture",
            "CFBundlePackageType": "BNDL", "RecallCaptureDistribution": true]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
        let distributionBundle = Bundle(url: bundleURL)!
        let distribution = await SpeakerDiarizationEngine(environment: environment, bundle: distributionBundle)
            .diarize(manifest: manifest, workspace: workspace)
        try check(distribution.timelines.isEmpty && !distribution.warnings.isEmpty, "Distribution must use bundled assets only")
        try check(String(contentsOf: root.appendingPathComponent("calls.txt"), encoding: .utf8) == calls,
            "Distribution executed an environment-supplied program")
        print("speaker-diarization-engine: passed (both tracks, timing, silence, overlap, missing assets, distribution override refusal)")
    }

    static func writeAudio(to url: URL, format: AVAudioFormat, value: Int16) throws {
        let output = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        buffer.int16ChannelData![0].initialize(repeating: value, count: 16_000)
        try output.write(from: buffer)
    }
}
