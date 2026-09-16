import Foundation

public enum RecordingStatus: String, Codable, Sendable {
    case recording
    case finalizing
    case readyForProcessing = "ready_for_processing"
    case processing
    case completed
    case failed
}

public struct AudioChunkDescriptor: Codable, Equatable, Sendable {
    public let index: Int
    public let track: AudioTrack
    public let relativePath: String
    public let startedAtMilliseconds: Int64
    public let durationMilliseconds: Int64
    public let byteCount: Int64

    enum CodingKeys: String, CodingKey {
        case index
        case track
        case relativePath = "relative_path"
        case startedAtMilliseconds = "started_at_ms"
        case durationMilliseconds = "duration_ms"
        case byteCount = "byte_count"
    }

    public init(
        index: Int,
        track: AudioTrack,
        relativePath: String,
        startedAtMilliseconds: Int64,
        durationMilliseconds: Int64,
        byteCount: Int64
    ) {
        self.index = index
        self.track = track
        self.relativePath = relativePath
        self.startedAtMilliseconds = startedAtMilliseconds
        self.durationMilliseconds = durationMilliseconds
        self.byteCount = byteCount
    }
}

public struct RecordingManifest: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let sessionID: String
    public let title: String
    public let captureMode: CaptureMode
    public let languageMode: LanguageMode
    public let startedAt: String
    public private(set) var status: RecordingStatus
    public let chunkDurationSeconds: Int
    public let maximumDurationSeconds: Int
    public let tracks: [AudioTrack]
    public private(set) var chunks: [AudioChunkDescriptor]
    public private(set) var updatedAt: String
    public private(set) var lastError: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sessionID = "session_id"
        case title
        case captureMode = "capture_mode"
        case languageMode = "language_mode"
        case startedAt = "started_at"
        case status
        case chunkDurationSeconds = "chunk_duration_seconds"
        case maximumDurationSeconds = "maximum_duration_seconds"
        case tracks
        case chunks
        case updatedAt = "updated_at"
        case lastError = "last_error"
    }

    public init(
        sessionID: UUID,
        title: String,
        captureMode: CaptureMode,
        languageMode: LanguageMode,
        startedAt: Date,
        tracks: [AudioTrack],
        chunkDurationSeconds: Int = 60,
        maximumDurationSeconds: Int = 10_800
    ) {
        let timestamp = Self.timestamp(startedAt)
        self.schemaVersion = "1.0"
        self.sessionID = sessionID.uuidString.lowercased()
        self.title = title
        self.captureMode = captureMode
        self.languageMode = languageMode
        self.startedAt = timestamp
        self.status = .recording
        self.chunkDurationSeconds = chunkDurationSeconds
        self.maximumDurationSeconds = maximumDurationSeconds
        self.tracks = tracks
        self.chunks = []
        self.updatedAt = timestamp
        self.lastError = nil
    }

    public mutating func append(_ chunk: AudioChunkDescriptor, at date: Date = .now) {
        chunks.append(chunk)
        updatedAt = Self.timestamp(date)
    }

    public mutating func setStatus(
        _ status: RecordingStatus,
        error: String? = nil,
        at date: Date = .now
    ) {
        self.status = status
        lastError = error
        updatedAt = Self.timestamp(date)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
