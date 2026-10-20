import Foundation

public struct SpeakerActivitySegment: Equatable, Sendable {
    public let startMilliseconds: Int64
    public let endMilliseconds: Int64
    public let speakerNumber: Int

    public init(startMilliseconds: Int64, endMilliseconds: Int64, speakerNumber: Int) {
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.speakerNumber = speakerNumber
    }
}

public struct SpeakerTimeline: Equatable, Sendable {
    public let segments: [SpeakerActivitySegment]

    public init(segments: [SpeakerActivitySegment]) {
        self.segments = segments
            .filter {
                $0.startMilliseconds >= 0
                    && $0.endMilliseconds > $0.startMilliseconds
                    && (1...99).contains($0.speakerNumber)
            }
            .sorted {
                if $0.startMilliseconds == $1.startMilliseconds {
                    return $0.speakerNumber < $1.speakerNumber
                }
                return $0.startMilliseconds < $1.startMilliseconds
            }
    }

    /// Tiny competing activity at a word's edges may be timing jitter. Interior
    /// overlap, balanced turns and insufficient coverage remain unknown.
    public func speakerLabel(
        startMilliseconds: Int64,
        endMilliseconds: Int64,
        minimumCoverageRatio: Double = 0.20,
        minimumCoverageMilliseconds: Int64 = 100
    ) -> String? {
        guard startMilliseconds >= 0, endMilliseconds > startMilliseconds,
              minimumCoverageRatio.isFinite, (0...1).contains(minimumCoverageRatio) else { return nil }
        let duration = endMilliseconds - startMilliseconds
        let required = max(minimumCoverageMilliseconds,
            Int64((Double(duration) * minimumCoverageRatio).rounded(.up)))
        let intersections = segments.compactMap { segment -> (speaker: Int, start: Int64, end: Int64)? in
            let start = max(startMilliseconds, segment.startMilliseconds)
            let end = min(endMilliseconds, segment.endMilliseconds)
            return end > start ? (segment.speakerNumber, start, end) : nil
        }
        let grouped = Dictionary(grouping: intersections, by: \.speaker)
        let coverage = grouped.mapValues { entries -> Int64 in
            let ordered = entries.sorted { $0.start < $1.start }
            var total: Int64 = 0
            var lastEnd = startMilliseconds
            for entry in ordered {
                total += max(0, entry.end - max(lastEnd, entry.start))
                lastEnd = max(lastEnd, entry.end)
            }
            return total
        }
        guard let best = coverage.max(by: { $0.value < $1.value }), best.value >= required else { return nil }
        let competitors = intersections.filter { $0.speaker != best.key }
        if !competitors.isEmpty {
            let tolerance = min(Int64(120), duration / 10)
            let competingCoverage = coverage.filter { $0.key != best.key }.values.reduce(0, +)
            guard competingCoverage <= tolerance,
                  competitors.allSatisfy({
                      $0.end <= startMilliseconds + tolerance || $0.start >= endMilliseconds - tolerance
                  }) else { return nil }
        }
        return String(format: "speaker_%02d", best.key)
    }

}

public enum RTTMParser {
    public static func parse(_ text: String) -> SpeakerTimeline {
        var segments: [SpeakerActivitySegment] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let fields = rawLine.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 8,
                  fields[0] == "SPEAKER",
                  let startSeconds = Double(fields[3]),
                  let durationSeconds = Double(fields[4]),
                  startSeconds.isFinite, durationSeconds.isFinite,
                  startSeconds >= 0,
                  durationSeconds > 0,
                  let speakerNumber = speakerNumber(from: String(fields[7])) else {
                continue
            }
            guard (startSeconds + durationSeconds) * 1_000 < Double(Int64.max) else { continue }
            let start = Int64((startSeconds * 1_000).rounded())
            let duration = Int64((durationSeconds * 1_000).rounded())
            guard duration > 0 else { continue }
            segments.append(SpeakerActivitySegment(
                startMilliseconds: start,
                endMilliseconds: start + duration,
                speakerNumber: speakerNumber
            ))
        }
        return SpeakerTimeline(segments: segments)
    }

    private static func speakerNumber(from value: String) -> Int? {
        guard value.hasPrefix("speaker_") else { return nil }
        let suffix = value.dropFirst("speaker_".count)
        guard let number = Int(suffix), (1...99).contains(number) else { return nil }
        return number
    }
}
