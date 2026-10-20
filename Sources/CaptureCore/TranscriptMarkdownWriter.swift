import Foundation

/// A readable view of every recognition result; exact records remain in canonical JSONL.
public struct TranscriptMarkdownWriter: Sendable {
    public init() {}

    public func data(metadata: SessionMetadata, utterances: [UtteranceRecord]) -> Data {
        var lines = ["# 文字起こし全文", "", "**" + escaped(metadata.title) + "**", "",
                     "開始: \(escaped(metadata.startedAt)) ／ 録音時間: \(Self.displayTime(metadata.durationMilliseconds))", "",
                     "時刻は録音開始からの経過時間です。話者番号はこの録音内だけで有効です。話者を判定できない箇所は「話者不明」と表示します。原文・認識信頼度などの詳細は `transcript.jsonl` に保存しています。", ""]
        let ordered = utterances.sorted { $0.startMilliseconds == $1.startMilliseconds ? $0.index < $1.index : $0.startMilliseconds < $1.startMilliseconds }
        let review = ordered.filter { needsSeparateReview($0, mode: metadata.captureMode) }
        let reviewIndices = Set(review.map(\.index))
        let main = ordered.filter { !reviewIndices.contains($0.index) }
        if !review.isEmpty {
            lines += ["短く信頼度の低いマイク音声 \(review.count)件は、本文を分断しないよう末尾の「確認が必要なマイク音声」に時刻付きで掲載しています。", ""]
        }
        var current: [UtteranceRecord] = []
        func flush() {
            guard let first = current.first else { return }
            let end = current.map(\.endMilliseconds).max() ?? first.endMilliseconds
            lines += ["## \(Self.displayTime(first.startMilliseconds)) – \(Self.displayTime(end))　\(speakerName(first))", ""]
            var paragraph: [String] = []
            var length = 0
            for row in current {
                paragraph.append(row.text)
                length += row.text.count
                if length >= 240 && sentenceEnds(row.text) {
                    lines += [escaped(TranscriptText.join(paragraph)), ""]
                    paragraph.removeAll(keepingCapacity: true)
                    length = 0
                }
            }
            if !paragraph.isEmpty { lines += [escaped(TranscriptText.join(paragraph)), ""] }
            current.removeAll(keepingCapacity: true)
        }
        for row in main {
            if let first = current.first, let prior = current.last {
                let length = current.reduce(0) { $0 + $1.text.count }
                let differentSpeaker = row.speaker != first.speaker || row.track != first.track
                let longPause = row.startMilliseconds - prior.endMilliseconds > 10_000
                let enoughText = (row.startMilliseconds - first.startMilliseconds >= 60_000 || length >= 600) && sentenceEnds(prior.text)
                if differentSpeaker || longPause || enoughText || length >= 1_200 { flush() }
            }
            current.append(row)
        }
        flush()
        if !review.isEmpty {
            lines += ["## 確認が必要なマイク音声", "",
                      "短いマイク音声の認識結果です。発言内容を確定する前に音声を確認してください。", ""]
            for row in review {
                lines += ["- \(Self.timestamp(row.startMilliseconds)) – \(Self.timestamp(row.endMilliseconds))　\(speakerName(row)): \(escaped(row.text))"]
            }
            lines.append("")
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func needsSeparateReview(_ row: UtteranceRecord, mode: CaptureMode) -> Bool {
        mode == .meet && row.track == .microphone && (row.confidence.map { $0 < 0.55 } ?? false)
            && row.endMilliseconds - row.startMilliseconds <= 1_500
            && row.text.trimmingCharacters(in: .whitespacesAndNewlines).count <= 3
    }

    private func sentenceEnds(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).last.map { "。！？.!?」\"".contains($0) } ?? false
    }

    private func speakerName(_ row: UtteranceRecord) -> String {
        if row.speaker == "self" { return "マイク音声" }
        let label: String
        let speaker = row.speaker.hasPrefix("mic_") ? String(row.speaker.dropFirst(4)) : row.speaker
        if speaker.hasPrefix("speaker_"), let number = Int(speaker.dropFirst(8)) {
            label = "話者\(number)"
        } else {
            label = "話者不明"
        }
        let source = row.track == .system ? "PC音声" : row.track == .microphone ? "マイク" : "音声"
        return "\(label)（\(source)）"
    }

    private static func displayTime(_ milliseconds: Int64) -> String {
        String(timestamp(milliseconds).split(separator: ".")[0])
    }

    private func escaped(_ text: String) -> String {
        // Speech containing Markdown must remain speech, not headings, links or HTML.
        let special = "\\`*_{}[]<>#+-.!|"
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .map { special.contains($0) ? "\\" + String($0) : String($0) }.joined()
            .replacingOccurrences(of: "&", with: "&amp;")
    }

    @discardableResult
    public func write(metadata: SessionMetadata, utterances: [UtteranceRecord], to destination: URL) throws -> URL {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try data(metadata: metadata, utterances: utterances).write(to: destination, options: .atomic)
        try validate(destination, metadata: metadata, utterances: utterances)
        return destination
    }

    public func validate(_ url: URL, metadata: SessionMetadata, utterances: [UtteranceRecord]) throws {
        guard try Data(contentsOf: url) == data(metadata: metadata, utterances: utterances) else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    public static func timestamp(_ milliseconds: Int64) -> String {
        let value = max(0, milliseconds)
        return String(format: "%02lld:%02lld:%02lld.%03lld", value / 3_600_000, value / 60_000 % 60,
                      value / 1_000 % 60, value % 1_000)
    }

}
