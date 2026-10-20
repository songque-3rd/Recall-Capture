import Foundation

public enum TranscriptValidationError: Error, Equatable, LocalizedError {
    case invalidIndex(expected: Int, actual: Int)
    case invalidTimeRange(index: Int)
    case timestampRegression(index: Int)
    case unsupportedSpeaker(index: Int, value: String)
    case unsupportedLanguage(index: Int, value: String)
    case invalidConfidence(index: Int)
    case destinationAlreadyExists
    case unreadableJSONLine(Int)
    case sessionMismatch

    public var errorDescription: String? {
        switch self {
        case let .invalidIndex(expected, actual):
            "発話番号が不正です。期待値: \(expected)、実際: \(actual)"
        case let .invalidTimeRange(index):
            "発話 \(index) の時刻範囲が不正です。"
        case let .timestampRegression(index):
            "発話 \(index) で開始時刻が逆行しています。"
        case let .unsupportedSpeaker(index, value):
            "発話 \(index) の話者ID \(value) は仕様外です。"
        case let .unsupportedLanguage(index, value):
            "発話 \(index) の言語 \(value) は仕様外です。"
        case let .invalidConfidence(index):
            "発話 \(index) の信頼度は0から1の範囲外です。"
        case .destinationAlreadyExists:
            "transcript.jsonl はすでに存在します。"
        case let .unreadableJSONLine(line):
            "JSONL の \(line) 行目を検証できません。"
        case .sessionMismatch:
            "保存済みの文字起こしが録音情報と一致しません。元のファイルを保持しました。"
        }
    }
}

public struct TranscriptJSONLWriter {
    private let encoder: JSONEncoder

    public init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    public func data(
        metadata: SessionMetadata,
        utterances: [UtteranceRecord]
    ) throws -> Data {
        try validate(utterances)
        var result = Data()
        result.append(try encoder.encode(metadata))
        result.append(0x0A)
        for utterance in utterances {
            result.append(try encoder.encode(utterance))
            result.append(0x0A)
        }
        try validateJSONLines(result)
        return result
    }

    @discardableResult
    public func write(
        metadata: SessionMetadata,
        utterances: [UtteranceRecord],
        to destination: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw TranscriptValidationError.destinationAlreadyExists
        }

        let encoded = try data(metadata: metadata, utterances: utterances)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".transcript-\(UUID().uuidString).partial")
        do {
            try encoded.write(to: temporary, options: [.atomic])
            let readBack = try Data(contentsOf: temporary)
            try validateJSONLines(readBack)
            try fileManager.moveItem(at: temporary, to: destination)
            return destination
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    public func read(from url: URL) throws -> (metadata: SessionMetadata, utterances: [UtteranceRecord]) {
        let lines = try Data(contentsOf: url).split(separator: 0x0A)
        guard let first = lines.first else { throw TranscriptValidationError.unreadableJSONLine(1) }
        let decoder = JSONDecoder()
        func requireType(_ line: Data, _ type: String, _ number: Int) throws {
            guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == type else {
                throw TranscriptValidationError.unreadableJSONLine(number)
            }
        }
        try requireType(Data(first), "session", 1)
        let metadata = try decoder.decode(SessionMetadata.self, from: Data(first))
        let utterances = try lines.dropFirst().enumerated().map { offset, line in
            try requireType(Data(line), "utterance", offset + 2)
            return try decoder.decode(UtteranceRecord.self, from: Data(line))
        }
        try validate(utterances)
        return (metadata, utterances)
    }

    /// Reuse a canonical transcript without running recognition again. App updates
    /// and time-zone changes do not invalidate an otherwise identical recording.
    public func read(from url: URL, matching expected: SessionMetadata) throws -> (metadata: SessionMetadata, utterances: [UtteranceRecord]) {
        let result = try read(from: url)
        let actual = result.metadata
        let formatter = ISO8601DateFormatter()
        guard actual.schemaVersion == expected.schemaVersion,
              actual.sessionID == expected.sessionID, actual.title == expected.title,
              actual.captureMode == expected.captureMode, actual.languageMode == expected.languageMode,
              actual.durationMilliseconds == expected.durationMilliseconds,
              let actualStart = formatter.date(from: actual.startedAt),
              let expectedStart = formatter.date(from: expected.startedAt), actualStart == expectedStart,
              let actualEnd = formatter.date(from: actual.endedAt),
              let expectedEnd = formatter.date(from: expected.endedAt), actualEnd == expectedEnd,
              !result.utterances.isEmpty else { throw TranscriptValidationError.sessionMismatch }
        return result
    }

    private func validate(_ utterances: [UtteranceRecord]) throws {
        var priorStart: Int64 = -1
        for (offset, utterance) in utterances.enumerated() {
            let expectedIndex = offset + 1
            guard utterance.index == expectedIndex else {
                throw TranscriptValidationError.invalidIndex(
                    expected: expectedIndex,
                    actual: utterance.index
                )
            }
            guard utterance.startMilliseconds >= 0,
                  utterance.endMilliseconds >= utterance.startMilliseconds else {
                throw TranscriptValidationError.invalidTimeRange(index: utterance.index)
            }
            guard utterance.startMilliseconds >= priorStart else {
                throw TranscriptValidationError.timestampRegression(index: utterance.index)
            }
            guard Self.validSpeaker(utterance.speaker) else {
                throw TranscriptValidationError.unsupportedSpeaker(
                    index: utterance.index,
                    value: utterance.speaker
                )
            }
            guard ["ja", "en", "und"].contains(utterance.language) else {
                throw TranscriptValidationError.unsupportedLanguage(
                    index: utterance.index,
                    value: utterance.language
                )
            }
            if let confidence = utterance.confidence,
               !(0 ... 1).contains(confidence) {
                throw TranscriptValidationError.invalidConfidence(index: utterance.index)
            }
            priorStart = utterance.startMilliseconds
        }
    }

    private func validateJSONLines(_ data: Data) throws {
        let lines = data.split(separator: 0x0A)
        for (offset, line) in lines.enumerated() {
            let object = try? JSONSerialization.jsonObject(with: Data(line))
            guard object is [String: Any] else {
                throw TranscriptValidationError.unreadableJSONLine(offset + 1)
            }
        }
    }

    private static func validSpeaker(_ value: String) -> Bool {
        if value == "self" || value == "unknown" {
            return true
        }
        let value = value.hasPrefix("mic_") ? String(value.dropFirst(4)) : value
        guard value.hasPrefix("speaker_"), value.count == 10 else {
            return false
        }
        let suffix = value.suffix(2)
        return suffix.utf8.allSatisfy { (48...57).contains($0) }
            && Int(suffix).map { (1...99).contains($0) } == true
    }
}
