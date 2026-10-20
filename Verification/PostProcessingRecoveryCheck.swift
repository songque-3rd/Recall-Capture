import CaptureCore
import Foundation

@main
enum PostProcessingRecoveryCheck {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(description: message) }
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let id = UUID()
        let workspace = RecordingWorkspacePaths(root: root, sessionID: id)
        try workspace.createDirectories(tracks: [.microphone])
        var manifest = RecordingManifest(sessionID: id, title: "全文の復旧", captureMode: .meet,
            languageMode: .japanese, startedAt: start, tracks: [.microphone])
        // Missing audio proves retry does not invoke recognition.
        manifest.append(.init(index: 1, track: .microphone, relativePath: "audio/absent.caf",
            startedAtMilliseconds: 0, durationMilliseconds: 10_000, byteCount: 1))
        manifest.setStatus(.failed)
        let metadata = SessionMetadata(sessionID: id, title: manifest.title, startedAt: start,
            endedAt: start.addingTimeInterval(10), captureMode: .meet, languageMode: .japanese,
            timezone: .current, appVersion: "old")
        let rows = [UtteranceRecord(index: 1, startMilliseconds: 0, endMilliseconds: 10_000,
            speaker: "mic_speaker_01", track: .microphone, language: "ja",
            text: "話者と全文を保存します。", confidence: 0.9)]
        let location = SessionLocation(directory: workspace.directory)
        try TranscriptJSONLWriter().write(metadata: metadata, utterances: rows, to: location.transcriptJSONL)
        let original = try Data(contentsOf: location.transcriptJSONL)
        let notes = workspace.directory.appendingPathComponent("transcript-notes.txt")
        try "話者判別の制限を保持する。\n".write(to: notes, atomically: true, encoding: .utf8)
        var failed = false
        do {
            _ = try await PostProcessingCoordinator(fileManager: FailingStageFileManager()).process(
                workspace: workspace, manifest: manifest, appVersion: "new", progress: { _ in })
        } catch { failed = true }
        try check(failed, "Save failure ignored")
        let savedFailure = try RecordingManifestStore().load(from: workspace.manifestURL)
        try check(savedFailure.status == .failed && (try Data(contentsOf: location.transcriptJSONL)) == original, "Failure lost canonical text")
        let recovered = try await PostProcessingCoordinator().process(workspace: workspace,
            manifest: savedFailure, appVersion: "new", progress: { _ in })
        try check(recovered.utteranceCount == 1 && recovered.warnings == ["話者判別の制限を保持する。"], "Retry lost text or limitations")
        try check(try Data(contentsOf: location.transcriptJSONL) == original, "Retry changed canonical text")
        try TranscriptMarkdownWriter().validate(location.transcriptMarkdown, metadata: metadata, utterances: rows)
        let completed = try RecordingManifestStore().load(from: workspace.manifestURL)
        try check(completed.status == .completed && completed.lastError == nil, "Retry incomplete")
        let previousMarkdown = try Data(contentsOf: location.transcriptMarkdown)
        try Data("corrupt".utf8).write(to: location.transcriptJSONL)
        failed = false
        do {
            _ = try await PostProcessingCoordinator().process(workspace: workspace,
                manifest: completed, appVersion: "new", progress: { _ in })
        } catch { failed = true }
        try check(failed && (try Data(contentsOf: location.transcriptMarkdown)) == previousMarkdown, "Corrupt cache replaced Markdown")
        let files = try FileManager.default.contentsOfDirectory(atPath: workspace.directory.path)
        try check(!files.contains { $0.hasPrefix(".transcript-save-") || $0.hasPrefix(".artifact-backup-") || $0 == "summary.pdf" }, "Unexpected artifacts")
        print("postprocessing-recovery: passed (save failure, cached retry without audio, retained limitations, corrupt cache)")
    }
}
private final class FailingStageFileManager: FileManager, @unchecked Sendable {
    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                 attributes: [FileAttributeKey: Any]? = nil) throws {
        if url.lastPathComponent.hasPrefix(".transcript-save-") {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}
