import Foundation

/// Validated replacement with rollback. Multi-file moves are not crash-atomic;
/// the session manifest stays processing until every artifact is validated.
public struct ArtifactTransaction {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) { self.fileManager = fileManager }

    public func commit(staged: [URL], to directory: URL, validate: () throws -> Void) throws {
        let backup = directory.appendingPathComponent(".artifact-backup-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: backup, withIntermediateDirectories: true)
        var originals: [(URL, URL)] = []
        var installed: [URL] = []
        do {
            for source in staged {
                let destination = directory.appendingPathComponent(source.lastPathComponent)
                if fileManager.fileExists(atPath: destination.path) {
                    let saved = backup.appendingPathComponent(source.lastPathComponent)
                    try fileManager.moveItem(at: destination, to: saved)
                    originals.append((saved, destination))
                }
            }
            for source in staged {
                let destination = directory.appendingPathComponent(source.lastPathComponent)
                try fileManager.moveItem(at: source, to: destination)
                installed.append(destination)
            }
            try validate()
        } catch {
            let originalError = error
            var rollbackErrors: [String] = []
            for destination in installed.reversed() {
                do { try fileManager.removeItem(at: destination) }
                catch { rollbackErrors.append(error.localizedDescription) }
            }
            for (saved, destination) in originals.reversed() {
                do { try fileManager.moveItem(at: saved, to: destination) }
                catch { rollbackErrors.append(error.localizedDescription) }
            }
            if rollbackErrors.isEmpty {
                try? fileManager.removeItem(at: backup)
                throw originalError
            }
            throw NSError(domain: "RecallCapture.ArtifactTransaction", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "保存に失敗しました。復旧用ファイルを \(backup.path) に残しました。\(originalError.localizedDescription) \(rollbackErrors.joined(separator: " / "))"
            ])
        }
        try? fileManager.removeItem(at: backup)
    }
}
