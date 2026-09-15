import Foundation

public enum CaptureMode: String, Codable, CaseIterable, Sendable {
    case meet
    case classroom
}

public enum LanguageMode: String, Codable, CaseIterable, Sendable {
    case japanese = "ja"
    case japaneseAndEnglish = "ja-en"
}

public enum AudioTrack: String, Codable, CaseIterable, Sendable {
    case microphone
    case system
    case mixed
}

public struct SessionMetadata: Codable, Equatable, Sendable {
    public let type = "session"
    public let schemaVersion: String
    public let sessionID: String
    public let title: String
    public let startedAt: String
    public let endedAt: String
    public let durationMilliseconds: Int64
    public let captureMode: CaptureMode
    public let languageMode: LanguageMode
    public let timezone: String
    public let appVersion: String

    enum CodingKeys: String, CodingKey {
        case type
        case schemaVersion = "schema_version"
        case sessionID = "session_id"
        case title
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationMilliseconds = "duration_ms"
        case captureMode = "capture_mode"
        case languageMode = "language_mode"
        case timezone
        case appVersion = "app_version"
    }

    public init(
        schemaVersion: String = "1.0",
        sessionID: UUID,
        title: String,
        startedAt: Date,
        endedAt: Date,
        captureMode: CaptureMode,
        languageMode: LanguageMode,
        timezone: TimeZone,
        appVersion: String
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID.uuidString.lowercased()
        self.title = title
        self.startedAt = Self.timestamp(startedAt, in: timezone)
        self.endedAt = Self.timestamp(endedAt, in: timezone)
        self.durationMilliseconds = max(0, Int64(endedAt.timeIntervalSince(startedAt) * 1_000))
        self.captureMode = captureMode
        self.languageMode = languageMode
        self.timezone = timezone.identifier
        self.appVersion = appVersion
    }

    private static func timestamp(_ date: Date, in timezone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        formatter.timeZone = timezone
        return formatter.string(from: date)
    }
}

public struct UtteranceRecord: Codable, Equatable, Sendable {
    public let type = "utterance"
    public let index: Int
    public let startMilliseconds: Int64
    public let endMilliseconds: Int64
    public let speaker: String
    public let track: AudioTrack
    public let language: String
    public let text: String
    public let confidence: Double?

    enum CodingKeys: String, CodingKey {
        case type
        case index
        case startMilliseconds = "start_ms"
        case endMilliseconds = "end_ms"
        case speaker
        case track
        case language
        case text
        case confidence
    }

    public init(
        index: Int,
        startMilliseconds: Int64,
        endMilliseconds: Int64,
        speaker: String,
        track: AudioTrack,
        language: String,
        text: String,
        confidence: Double?
    ) {
        self.index = index
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.speaker = speaker
        self.track = track
        self.language = language
        self.text = text
        self.confidence = confidence
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(index, forKey: .index)
        try container.encode(startMilliseconds, forKey: .startMilliseconds)
        try container.encode(endMilliseconds, forKey: .endMilliseconds)
        try container.encode(speaker, forKey: .speaker)
        try container.encode(track, forKey: .track)
        try container.encode(language, forKey: .language)
        try container.encode(text, forKey: .text)
        if let confidence {
            try container.encode(confidence, forKey: .confidence)
        } else {
            try container.encodeNil(forKey: .confidence)
        }
    }
}
