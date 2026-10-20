import Foundation

/// Recognition timing must survive until speaker attribution is complete.
public struct TimedTranscriptSegment: Sendable {
    public let startMilliseconds: Int64
    public let endMilliseconds: Int64
    public let track: AudioTrack
    public let language: String
    public let text: String
    public let confidence: Double?

    public init(startMilliseconds: Int64, endMilliseconds: Int64, track: AudioTrack,
                language: String, text: String, confidence: Double?) {
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = max(startMilliseconds, endMilliseconds)
        self.track = track
        self.language = language
        self.text = text
        self.confidence = confidence
    }
}

public struct TranscriptAssembler: Sendable {
    public init() {}

    public func assemble(segments: [TimedTranscriptSegment], captureMode: CaptureMode,
                         timelines: [AudioTrack: SpeakerTimeline]) -> [UtteranceRecord] {
        var output: [UtteranceRecord] = []
        for track in AudioTrack.allCases {
            let ordered = segments.filter { $0.track == track && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .sorted { $0.startMilliseconds < $1.startMilliseconds }
            var current: [TimedTranscriptSegment] = []
            var currentSpeaker = "unknown"
            var prior: TimedTranscriptSegment?
            var priorSpeaker = "unknown"

            func flush() {
                guard let first = current.first else { return }
                output.append(UtteranceRecord(index: 0, startMilliseconds: first.startMilliseconds,
                    endMilliseconds: current.map(\.endMilliseconds).max() ?? first.endMilliseconds, speaker: currentSpeaker,
                    track: track, language: first.language, text: TranscriptText.join(current.map(\.text)),
                    confidence: TranscriptText.confidence(current.map(\.confidence))))
                current.removeAll(keepingCapacity: true)
            }

            for segment in ordered {
                let duration = segment.endMilliseconds - segment.startMilliseconds
                var speaker = timelines[track]?.speakerLabel(startMilliseconds: segment.startMilliseconds,
                        endMilliseconds: segment.endMilliseconds, minimumCoverageRatio: 0.5,
                        minimumCoverageMilliseconds: min(100, max(1, duration))) ?? "unknown"
                if track == .microphone, speaker.hasPrefix("speaker_") { speaker = "mic_" + speaker }
                // Punctuation has no independent voice. Attach only an adjacent punctuation token,
                // never an unassigned word, to the preceding recognition token.
                let punctuation = segment.text.unicodeScalars.allSatisfy {
                    CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines).contains($0)
                }
                if punctuation, let prior, (-100...500).contains(segment.startMilliseconds - prior.endMilliseconds) {
                    speaker = priorSpeaker
                }
                if let last = current.last, let first = current.first,
                   speaker != currentSpeaker || segment.language != first.language ||
                    segment.startMilliseconds - last.endMilliseconds > 800 ||
                    (!punctuation && segment.startMilliseconds - first.startMilliseconds >= 15_000) {
                    flush()
                }
                if current.isEmpty { currentSpeaker = speaker }
                current.append(segment)
                prior = segment
                priorSpeaker = speaker
                if segment.text.trimmingCharacters(in: .whitespacesAndNewlines).last.map({ "。！？.!?".contains($0) }) == true {
                    flush()
                }
            }
            flush()
        }
        return output.sorted {
            if $0.startMilliseconds == $1.startMilliseconds { return $0.track.rawValue < $1.track.rawValue }
            return $0.startMilliseconds < $1.startMilliseconds
        }.enumerated().map { index, row in
            UtteranceRecord(index: index + 1, startMilliseconds: row.startMilliseconds,
                endMilliseconds: row.endMilliseconds, speaker: row.speaker, track: row.track,
                language: row.language, text: row.text, confidence: row.confidence)
        }
    }
}
