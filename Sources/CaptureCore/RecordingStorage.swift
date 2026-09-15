import Foundation

public struct RecordingDestinationStore {
    public static let defaultKey = "recordingDestinationPath"

    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = RecordingDestinationStore.defaultKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func load(defaultURL: URL) -> URL {
        guard let path = defaults.string(forKey: key), !path.isEmpty else {
            return defaultURL.standardizedFileURL
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    public func save(_ url: URL) {
        defaults.set(url.standardizedFileURL.path, forKey: key)
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }
}

public struct RecentRecordingStore {
    public static let defaultKey = "lastRecordingWorkspacePath"

    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = RecentRecordingStore.defaultKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> URL? {
        guard let path = defaults.string(forKey: key), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    public func save(_ url: URL) {
        defaults.set(url.standardizedFileURL.path, forKey: key)
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }
}

public enum RecordingStorageValidationError: LocalizedError, Equatable {
    case pathIsNotDirectory(String)
    case cannotCreateDirectory(String)
    case cannotWrite(String)

    public var errorDescription: String? {
        switch self {
        case let .pathIsNotDirectory(path):
            "保存先がフォルダではありません: \(path)"
        case let .cannotCreateDirectory(path):
            "保存先フォルダを作成できません: \(path)"
        case let .cannotWrite(path):
            "保存先へ書き込めません。アクセス権と空き容量を確認してください: \(path)"
        }
    }
}

public struct RecordingStorageValidator: Sendable {
    public init() {}

    public func validate(
        root: URL,
        fileManager: FileManager = .default
    ) throws {
        let root = root.standardizedFileURL
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw RecordingStorageValidationError.pathIsNotDirectory(root.path)
            }
        } else {
            do {
                try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            } catch {
                throw RecordingStorageValidationError.cannotCreateDirectory(root.path)
            }
        }

        let probe = root.appendingPathComponent(
            ".recall-capture-write-test-\(UUID().uuidString)",
            isDirectory: false
        )
        do {
            try Data("Recall Capture".utf8).write(to: probe, options: [.atomic])
            try fileManager.removeItem(at: probe)
        } catch {
            try? fileManager.removeItem(at: probe)
            throw RecordingStorageValidationError.cannotWrite(root.path)
        }
    }
}
