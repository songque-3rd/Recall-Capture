import Foundation
import CaptureCore

@main
struct TranscriptAssemblyCheck {
    struct Failure: Error, CustomStringConvertible { let description: String }
    private func check(_ condition: @autoclosure () -> Bool) throws {
        guard condition() else { throw Failure(description: "Transcript assembly regression failed") }
    }
    static func main() throws {
        let checks = Self()
        try checks.speakerChangeWithinOldGroupingWindow()
        try checks.shortWordsAndPunctuation()
        try checks.ambiguousWordsStayUnknown()
        try checks.boundaryJitterAndMicrophoneSpeakers()
        try checks.readableMarkdownPreservesReviewAndSpeakerChanges()
        print("transcript assembly: speaker changes, short words, ambiguous coverage, and readable Markdown passed")
    }
    private func segment(_ start: Int64, _ end: Int64, _ text: String,
                         track: AudioTrack = .system) -> TimedTranscriptSegment {
        .init(startMilliseconds: start, endMilliseconds: end, track: track,
              language: "ja", text: text, confidence: 0.9)
    }

    func speakerChangeWithinOldGroupingWindow() throws {
        let timeline = SpeakerTimeline(segments: [
            .init(startMilliseconds: 0, endMilliseconds: 1_000, speakerNumber: 1),
            .init(startMilliseconds: 1_000, endMilliseconds: 2_000, speakerNumber: 2)
        ])
        let rows = TranscriptAssembler().assemble(segments: [
            segment(100, 800, "確認します"), segment(1_100, 1_800, "お願いします")
        ], captureMode: .meet, timelines: [.system: timeline])
        try check(rows.map(\.speaker) == ["speaker_01", "speaker_02"])
        try check(rows.map(\.text) == ["確認します", "お願いします"])
        try check(rows.map(\.index) == [1, 2])
    }

    func shortWordsAndPunctuation() throws {
        let timeline = SpeakerTimeline(segments: [
            .init(startMilliseconds: 0, endMilliseconds: 380, speakerNumber: 1)
        ])
        let rows = TranscriptAssembler().assemble(segments: [
            segment(0, 80, "今日"), segment(90, 180, "は"),
            segment(190, 380, "晴れです"), segment(390, 400, "。")
        ], captureMode: .meet, timelines: [.system: timeline])
        try check(rows.count == 1)
        try check(rows.first?.speaker == "speaker_01")
        try check(rows.first?.text == "今日は晴れです。")
        try check(rows.first?.endMilliseconds == 400)
    }

    func ambiguousWordsStayUnknown() throws {
        let sparse = SpeakerTimeline(segments: [
            .init(startMilliseconds: 0, endMilliseconds: 80, speakerNumber: 1)
        ])
        let overlap = SpeakerTimeline(segments: [
            .init(startMilliseconds: 0, endMilliseconds: 1_000, speakerNumber: 1),
            .init(startMilliseconds: 500, endMilliseconds: 1_000, speakerNumber: 2)
        ])
        for timeline in [sparse, overlap] {
            let rows = TranscriptAssembler().assemble(segments: [segment(0, 1_000, "確認中")],
                captureMode: .meet, timelines: [.system: timeline])
            try check(rows.first?.speaker == "unknown")
        }
        let rows = TranscriptAssembler().assemble(segments: [
            segment(0, 80, "今日"), segment(90, 300, "明日")
        ], captureMode: .meet, timelines: [.system: sparse])
        try check(rows.map(\.speaker) == ["speaker_01", "unknown"])
        let mic = TranscriptAssembler().assemble(segments: [segment(0, 80, "はい", track: .microphone)],
            captureMode: .meet, timelines: [:])
        try check(mic.first?.speaker == "unknown")
    }

    func readableMarkdownPreservesReviewAndSpeakerChanges() throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let metadata = SessionMetadata(sessionID: UUID(), title: "講義", startedAt: start,
            endedAt: start.addingTimeInterval(60), captureMode: .meet,
            languageMode: .japanese, timezone: .current, appVersion: "test")
        func row(_ index: Int, _ start: Int64, _ end: Int64, _ text: String,
                 speaker: String = "speaker_01", track: AudioTrack = .system,
                 confidence: Double? = 0.9) -> UtteranceRecord {
            .init(index: index, startMilliseconds: start, endMilliseconds: end,
                  speaker: speaker, track: track, language: "ja", text: text, confidence: confidence)
        }
        let rows = [row(1, 0, 1_000, "この授業では"),
                    row(2, 500, 800, "あ", speaker: "mic_speaker_02", track: .microphone, confidence: 0.12),
                    row(3, 1_000, 2_000, "資料を参照します"), row(4, 2_000, 2_010, "。"),
                    row(5, 2_500, 3_000, "はい。", speaker: "speaker_02"),
                    row(6, 3_100, 3_600, "確認中。", speaker: "unknown"),
                    row(7, 4_000, 4_500, "はい", speaker: "self", track: .microphone, confidence: 0.95)]
        let text = String(decoding: TranscriptMarkdownWriter().data(metadata: metadata, utterances: rows), as: UTF8.self)
        try check(text.contains("この授業では資料を参照します。"))
        try check(text.contains("話者1（PC音声）") && text.contains("話者2（PC音声）"))
        try check(text.contains("話者不明（PC音声）") && text.contains("マイク音声"))
        try check(text.contains("00:00:00.500 – 00:00:00.800　話者2（マイク）: あ"))
        try check(text.components(separatedBy: "\n## ").count - 1 == 5)
        try check(!text.contains("```"))
        try check(rows[1].text == "あ")
    }

    func boundaryJitterAndMicrophoneSpeakers() throws {
        let boundary = SpeakerTimeline(segments: [
            .init(startMilliseconds: 0, endMilliseconds: 1_040, speakerNumber: 1),
            .init(startMilliseconds: 1_040, endMilliseconds: 2_000, speakerNumber: 2)
        ])
        try check(boundary.speakerLabel(startMilliseconds: 1_000, endMilliseconds: 2_000) == "speaker_02")
        let interior = SpeakerTimeline(segments: [
            .init(startMilliseconds: 0, endMilliseconds: 1_000, speakerNumber: 1),
            .init(startMilliseconds: 500, endMilliseconds: 540, speakerNumber: 2)
        ])
        try check(interior.speakerLabel(startMilliseconds: 0, endMilliseconds: 1_000) == nil)
        let duplicates = SpeakerTimeline(segments: Array(repeating:
            .init(startMilliseconds: 0, endMilliseconds: 80, speakerNumber: 1), count: 5))
        try check(duplicates.speakerLabel(startMilliseconds: 0, endMilliseconds: 1_000) == nil)
        let rows = TranscriptAssembler().assemble(segments: [
            segment(100, 800, "確認します", track: .microphone),
            segment(1_100, 1_800, "お願いします", track: .microphone)
        ], captureMode: .meet, timelines: [.microphone: boundary])
        try check(rows.map(\.speaker) == ["mic_speaker_01", "mic_speaker_02"])
        let malformed = RTTMParser.parse("""
        SPEAKER test 1 nan 1 <NA> <NA> speaker_01
        SPEAKER test 1 0 inf <NA> <NA> speaker_01
        SPEAKER test 1 1e100 1 <NA> <NA> speaker_01
        SPEAKER test 1 0 1 <NA> <NA> speaker_02
        """)
        try check(malformed.segments.count == 1 && malformed.segments.first?.speakerNumber == 2)
    }
}
