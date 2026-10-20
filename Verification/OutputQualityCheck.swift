import CaptureCore
import Foundation

@main
enum OutputQualityCheck {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(description: message) }
    }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let metadata = SessionMetadata(sessionID: UUID(), title: "長時間の全文保存",
            startedAt: start, endedAt: start.addingTimeInterval(10_800), captureMode: .meet,
            languageMode: .japaneseAndEnglish, timezone: .current, appVersion: "verification")
        let rows = (1...6_000).map { index in
            UtteranceRecord(index: index, startMilliseconds: Int64(index - 1) * 1_800,
                endMilliseconds: Int64(index) * 1_800,
                speaker: index % 2 == 0 ? "mic_speaker_01" : "speaker_01",
                track: index % 2 == 0 ? .microphone : .system, language: "ja",
                text: index == 6_000 ? "最終発話 SENTINELEND" : "発話\(index)。資料を確認します。", confidence: 0.9)
        }
        let location = SessionLocation(directory: root)
        try TranscriptJSONLWriter().write(metadata: metadata, utterances: rows, to: location.transcriptJSONL)
        try check(try TranscriptJSONLWriter().read(from: location.transcriptJSONL).utterances == rows, "JSONL lost text")
        try TranscriptMarkdownWriter().write(metadata: metadata, utterances: rows, to: location.transcriptMarkdown)
        try TranscriptMarkdownWriter().validate(location.transcriptMarkdown, metadata: metadata, utterances: rows)
        let markdown = try String(contentsOf: location.transcriptMarkdown, encoding: .utf8)
        try check(markdown.contains("SENTINELEND") && markdown.contains("話者1（マイク）"), "Markdown lost tail or identity")
        let literal = UtteranceRecord(index: 1, startMilliseconds: 0, endMilliseconds: 1_000,
            speaker: "unknown", track: .system, language: "ja", text: "# 発話の記号\n[リンク](https://example.com) **強調**", confidence: nil)
        let escaped = String(decoding: TranscriptMarkdownWriter().data(metadata: metadata, utterances: [literal]), as: UTF8.self)
        try check(!escaped.contains("\n# 発話の記号") && !escaped.contains("[リンク](https://example.com)"), "Speech became Markdown syntax")
        for failValidation in [true, false] {
            let directory = root.appendingPathComponent(failValidation ? "validation-rollback" : "move-rollback", isDirectory: true)
            let stage = directory.appendingPathComponent("stage", isDirectory: true)
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            let names = ["transcript.jsonl", "transcript.md"]
            for name in names {
                try Data("original \(name)".utf8).write(to: directory.appendingPathComponent(name))
                if failValidation || name != "transcript.md" {
                    try Data("replacement \(name)".utf8).write(to: stage.appendingPathComponent(name))
                }
            }
            var caught = false
            do {
                try ArtifactTransaction().commit(staged: names.map { stage.appendingPathComponent($0) }, to: directory) {
                    if failValidation { throw Failure(description: "Injected validation failure") }
                }
            } catch { caught = true }
            try check(caught, "Injected transaction failure ignored")
            for name in names {
                try check(try Data(contentsOf: directory.appendingPathComponent(name)) == Data("original \(name)".utf8), "Rollback lost text")
            }
        }
        var limit = RecordingLimit()
        try check(limit.durationSeconds == 7_200 && limit.poll(elapsedSeconds: 6_899) == nil, "Wrong default deadline")
        try check(limit.poll(elapsedSeconds: 6_900) == .warning(minutes: 5), "Five-minute warning missing")
        try check(limit.poll(elapsedSeconds: 6_910) == nil, "Warning repeated")
        try check(limit.poll(elapsedSeconds: 7_140) == .warning(minutes: 1), "One-minute warning missing")
        limit.extend()
        try check(limit.durationSeconds == 8_100 && limit.poll(elapsedSeconds: 7_200) == nil, "Extension failed")
        try check(limit.poll(elapsedSeconds: 8_100) == .stop, "Deadline did not stop")
        var late = RecordingLimit()
        try check(late.poll(elapsedSeconds: 7_150) == .warning(minutes: 1) && late.poll(elapsedSeconds: 7_151) == nil, "Resume repeated warnings")
        var short = RecordingLimit(seconds: 300)
        try check(short.poll(elapsedSeconds: 0) == nil && short.poll(elapsedSeconds: 240) == .warning(minutes: 1), "Short limit warns at start")
        var maximum = RecordingLimit(seconds: Int.max)
        maximum.extend()
        try check(maximum.durationSeconds == 43_200, "Extension exceeded maximum")
        let silence = AudioSignalLevel(rms: 0, peak: 0)
        let sound = AudioSignalLevel(rms: 0.1, peak: 0.3)
        try check(!silence.hasSound && silence.meterValue == 0 && sound.hasSound && sound.meterValue > 0.6, "Signal invalid")
        try check(AudioSignalLevel(rms: .nan, peak: .infinity) == silence, "Invalid signal contaminated indicator")
        try check(AudioSignalLevel(rms: 0.5, peak: 1).isClipping, "Clipping missing")
        print("output-quality: passed (6000 utterances, literal Markdown, rollback, deadlines, signal levels)")
    }
}
