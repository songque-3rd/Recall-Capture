import Foundation

public struct RecordingWorkspacePaths: Equatable, Sendable {
    public let directory: URL
    public let audioDirectory: URL
    public let manifestURL: URL

    public init(root: URL, sessionID: UUID) {
        directory = root.appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
        audioDirectory = directory.appendingPathComponent("audio", isDirectory: true)
        manifestURL = directory.appendingPathComponent("recording-manifest.json")
    }

    public init(
        root: URL,
        startedAt: Date,
        title: String,
        sessionID: UUID,
        policy: SessionPathPolicy = SessionPathPolicy()
    ) {
        let location = policy.location(
            under: root,
            startedAt: startedAt,
            title: title,
            sessionID: sessionID
        )
        self.init(directory: location.directory)
    }

    public init(directory: URL) {
        self.directory = directory
        audioDirectory = directory.appendingPathComponent("audio", isDirectory: true)
        manifestURL = directory.appendingPathComponent("recording-manifest.json")
    }

    public func trackDirectory(_ track: AudioTrack) -> URL {
        audioDirectory.appendingPathComponent(track.rawValue, isDirectory: true)
    }

    public func partialChunkURL(track: AudioTrack, index: Int) -> URL {
        trackDirectory(track).appendingPathComponent(Self.chunkName(index) + ".partial.caf")
    }

    public func completedChunkURL(track: AudioTrack, index: Int) -> URL {
        trackDirectory(track).appendingPathComponent(Self.chunkName(index) + ".caf")
    }

    public func relativeCompletedChunkPath(track: AudioTrack, index: Int) -> String {
        "audio/\(track.rawValue)/\(Self.chunkName(index)).caf"
    }

    public func createDirectories(
        tracks: [AudioTrack],
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for track in tracks {
            try fileManager.createDirectory(
                at: trackDirectory(track),
                withIntermediateDirectories: true
            )
        }
    }

    private static func chunkName(_ index: Int) -> String {
        String(format: "%06d", index)
    }
}

public struct RecordingManifestStore: Sendable {
    public init() {}

    public func save(_ manifest: RecordingManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    public func load(from url: URL) throws -> RecordingManifest {
        try JSONDecoder().decode(RecordingManifest.self, from: Data(contentsOf: url))
    }
}

public struct RecordingRecoveryCandidate: Equatable, Sendable {
    public let paths: RecordingWorkspacePaths
    public let manifest: RecordingManifest

    public init(paths: RecordingWorkspacePaths, manifest: RecordingManifest) {
        self.paths = paths
        self.manifest = manifest
    }
}

public struct RecordingRecoveryScanner: Sendable {
    private let store = RecordingManifestStore()

    public init() {}

    public func scan(root: URL, fileManager: FileManager = .default) -> [RecordingRecoveryCandidate] {
        let legacyDirectories = childDirectories(of: root, fileManager: fileManager)
        let nestedDirectories = legacyDirectories
            .filter { isYearFolder($0.lastPathComponent) }
            .flatMap { year in
                childDirectories(of: year, fileManager: fileManager)
                    .filter { isMonthFolder($0.lastPathComponent) }
            }
            .flatMap { childDirectories(of: $0, fileManager: fileManager) }

        return (legacyDirectories + nestedDirectories).compactMap { directory in
            let paths = RecordingWorkspacePaths(directory: directory)
            guard let manifest = try? store.load(from: paths.manifestURL) else {
                return nil
            }
            return RecordingRecoveryCandidate(paths: paths, manifest: manifest)
        }
        .sorted { $0.manifest.startedAt < $1.manifest.startedAt }
    }

    private func childDirectories(of root: URL, fileManager: FileManager) -> [URL] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return contents.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    private func isYearFolder(_ name: String) -> Bool {
        name.count == 4 && name.allSatisfy(\.isNumber)
    }

    private func isMonthFolder(_ name: String) -> Bool {
        guard name.count == 7,
              name[name.index(name.startIndex, offsetBy: 4)] == "-" else {
            return false
        }
        return name.enumerated().allSatisfy { offset, character in
            offset == 4 ? character == "-" : character.isNumber
        }
    }
}
