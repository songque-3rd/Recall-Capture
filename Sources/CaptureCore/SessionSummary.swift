import Foundation

public struct SummarySection: Equatable, Sendable {
    public let title: String
    public let items: [String]

    public init(title: String, items: [String]) {
        self.title = title
        self.items = items
    }
}

public struct SessionSummary: Equatable, Sendable {
    public let title: String
    public let overview: String
    public let sections: [SummarySection]
    public let warnings: [String]

    public init(
        title: String,
        overview: String,
        sections: [SummarySection],
        warnings: [String]
    ) {
        self.title = title
        self.overview = overview
        self.sections = sections
        self.warnings = warnings
    }
}

public struct LocalSummaryBuilder: Sendable {
    public init() {}

    public func build(
        metadata: SessionMetadata,
        utterances: [UtteranceRecord]
    ) -> SessionSummary {
        let usable = utterances.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let overview = overview(from: usable)
        let sections = metadata.captureMode == .meet
            ? meetingSections(from: usable)
            : classroomSections(from: usable)

        var warnings = ["端末内の文字起こしから発言を抽出して作成した要約です。重要事項は原文も確認してください。"]
        let confidenceValues = usable.compactMap(\.confidence)
        if !confidenceValues.isEmpty,
           confidenceValues.reduce(0, +) / Double(confidenceValues.count) < 0.55 {
            warnings.append("音声認識の平均信頼度が低いため、誤認識が含まれる可能性があります。")
        }
        if metadata.captureMode == .meet {
            warnings.append("システム音声内の複数話者は speaker_01 としてまとめています。")
        } else {
            warnings.append("対面録音の話者は unknown として記録しています。")
        }

        return SessionSummary(
            title: metadata.title,
            overview: overview,
            sections: sections,
            warnings: warnings
        )
    }

    private func overview(from utterances: [UtteranceRecord]) -> String {
        let selected = distinct(utterances, limit: 4)
        guard !selected.isEmpty else { return "要約できる発話がありませんでした。" }
        let text = selected.map(\.text).joined(separator: " ")
        return String(text.prefix(360))
    }

    private func meetingSections(from utterances: [UtteranceRecord]) -> [SummarySection] {
        [
            SummarySection(
                title: "主な内容",
                items: timelineItems(distinct(utterances, limit: 8))
            ),
            SummarySection(
                title: "決定事項",
                items: matchedItems(
                    utterances,
                    keywords: ["決定", "決まり", "合意", "確定", "でいきます", "にします"],
                    empty: "明示的な決定事項は文字起こしから検出できませんでした。"
                )
            ),
            SummarySection(
                title: "対応事項",
                items: matchedItems(
                    utterances,
                    keywords: ["対応", "担当", "お願いします", "やります", "期限", "までに", "タスク"],
                    empty: "明示的な対応事項は文字起こしから検出できませんでした。"
                )
            ),
            SummarySection(
                title: "未解決・次回確認",
                items: matchedItems(
                    utterances,
                    keywords: ["未定", "確認", "検討", "次回", "課題", "わから", "でしょうか", "ですか"],
                    empty: "明示的な未解決事項は文字起こしから検出できませんでした。"
                )
            )
        ]
    }

    private func classroomSections(from utterances: [UtteranceRecord]) -> [SummarySection] {
        [
            SummarySection(
                title: "講義の主要内容",
                items: timelineItems(distinct(utterances, limit: 10))
            ),
            SummarySection(
                title: "復習ポイント",
                items: matchedItems(
                    utterances,
                    keywords: ["重要", "ポイント", "覚え", "試験", "課題", "まとめ", "つまり", "なので"],
                    empty: "明示的な復習ポイントは文字起こしから検出できませんでした。"
                )
            )
        ]
    }

    private func matchedItems(
        _ utterances: [UtteranceRecord],
        keywords: [String],
        empty: String
    ) -> [String] {
        let matched = utterances.filter { utterance in
            let normalized = utterance.text.lowercased()
            return keywords.contains { normalized.contains($0) }
        }
        let items = timelineItems(distinct(matched, limit: 8))
        return items.isEmpty ? [empty] : items
    }

    private func timelineItems(_ utterances: [UtteranceRecord]) -> [String] {
        utterances.map { "[\(timestamp($0.startMilliseconds))] \($0.text)" }
    }

    private func distinct(_ utterances: [UtteranceRecord], limit: Int) -> [UtteranceRecord] {
        var seen = Set<String>()
        return utterances.filter { utterance in
            let key = utterance.text
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, seen.insert(key).inserted else { return false }
            return true
        }.prefix(limit).map { $0 }
    }

    private func timestamp(_ milliseconds: Int64) -> String {
        let seconds = max(0, milliseconds / 1_000)
        return String(format: "%02d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
    }
}
