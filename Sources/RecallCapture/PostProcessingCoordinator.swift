import CaptureCore
import Foundation
import NaturalLanguage

enum PostProcessingError: LocalizedError {
    case invalidManifest
    case noAudioChunks
    case missingAudio(String)
    case noSpeechDetected
    case incompleteArtifacts

    var errorDescription: String? {
        switch self {
        case .invalidManifest:
            "録音情報を読み取れませんでした。"
        case .noAudioChunks:
            "処理できる音声チャンクがありません。"
        case let .missingAudio(path):
            "音声チャンクが見つかりません: \(path)"
        case .noSpeechDetected:
            "音声から発話を検出できませんでした。音声ファイルは再処理用に残しています。"
        case .incompleteArtifacts:
            "文字起こし全文とJSONLを確定できませんでした。"
        }
    }
}

struct PostProcessingResult: Sendable {
    let workspace: RecordingWorkspacePaths
    let transcriptURL: URL
    let transcriptMarkdownURL: URL
    let warnings: [String]
    let utteranceCount: Int
}

final class PostProcessingCoordinator: @unchecked Sendable {
    typealias ProgressHandler = @Sendable (SessionState) async -> Void

    private let fileManager: FileManager
    private let manifestStore = RecordingManifestStore()
    private let transcriptWriter = TranscriptJSONLWriter()
    private let markdownWriter = TranscriptMarkdownWriter()
    private let recognitionEngine = SpeechRecognitionEngine()
    private let diarizationEngine = SpeakerDiarizationEngine()

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func process(
        workspace: RecordingWorkspacePaths,
        manifest originalManifest: RecordingManifest,
        appVersion: String,
        progress: @escaping ProgressHandler
    ) async throws -> PostProcessingResult {
        var manifest = originalManifest
        do {
            guard UUID(uuidString: manifest.sessionID) != nil else {
                throw PostProcessingError.invalidManifest
            }
            guard !manifest.chunks.isEmpty else {
                throw PostProcessingError.noAudioChunks
            }

            manifest.setStatus(.processing)
            try manifestStore.save(manifest, to: workspace.manifestURL)

            guard let sessionID = UUID(uuidString: manifest.sessionID),
                  let startedAt = Self.date(from: manifest.startedAt) else {
                throw PostProcessingError.invalidManifest
            }
            let durationMilliseconds = manifest.chunks.map {
                $0.startedAtMilliseconds + $0.durationMilliseconds
            }.max() ?? 0
            let expectedMetadata = SessionMetadata(
                sessionID: sessionID, title: manifest.title, startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(Double(durationMilliseconds) / 1_000),
                captureMode: manifest.captureMode, languageMode: manifest.languageMode,
                timezone: .current, appVersion: appVersion
            )
            let transcriptURL = SessionLocation(directory: workspace.directory).transcriptJSONL
            let cached = fileManager.fileExists(atPath: transcriptURL.path)
                ? try transcriptWriter.read(from: transcriptURL, matching: expectedMetadata) : nil
            let metadata: SessionMetadata
            let utterances: [UtteranceRecord]
            let warnings: [String]
            await progress(.detectingSpeech)
            if let cached {
                // The log is canonical. Repairing derived Markdown must preserve recognition.
                await progress(.transcribing)
                await progress(.diarizing)
                metadata = cached.metadata
                utterances = cached.utterances
                let notes = workspace.directory.appendingPathComponent("transcript-notes.txt")
                warnings = (try? String(contentsOf: notes, encoding: .utf8))?
                    .split(separator: "\n").map(String.init) ?? []
            } else {
                try await recognitionEngine.authorize()
                await progress(.transcribing)
                let recognized = try await transcribe(
                    manifest: manifest, workspace: workspace,
                    locales: recognitionLocales(for: manifest.languageMode)
                )
                guard !recognized.isEmpty else { throw PostProcessingError.noSpeechDetected }
                await progress(.diarizing)
                let diarization = await diarizationEngine.diarize(manifest: manifest, workspace: workspace)
                metadata = expectedMetadata
                utterances = makeUtterances(from: recognized, captureMode: manifest.captureMode,
                    timelines: diarization.timelines)
                warnings = diarization.warnings
            }

            await progress(.formatting)
            await progress(.writingArtifacts)
            try writeTranscriptArtifacts(workspace: workspace, metadata: metadata, utterances: utterances)
            let location = SessionLocation(directory: workspace.directory)
            await progress(.validatingArtifacts)
            let saved = try transcriptWriter.read(from: location.transcriptJSONL, matching: metadata)
            guard !saved.utterances.isEmpty else { throw PostProcessingError.incompleteArtifacts }
            try markdownWriter.validate(location.transcriptMarkdown, metadata: saved.metadata, utterances: saved.utterances)
            // Keep processing limitations next to the transcript for later review.
            let notes = workspace.directory.appendingPathComponent("transcript-notes.txt")
            try (warnings.isEmpty ? "" : warnings.joined(separator: "\n") + "\n")
                .write(to: notes, atomically: true, encoding: .utf8)

            manifest.setStatus(.completed)
            try manifestStore.save(manifest, to: workspace.manifestURL)
            return PostProcessingResult(
                workspace: workspace,
                transcriptURL: location.transcriptJSONL,
                transcriptMarkdownURL: location.transcriptMarkdown,
                warnings: warnings,
                utteranceCount: utterances.count
            )
        } catch {
            manifest.setStatus(.failed, error: error.localizedDescription)
            try? manifestStore.save(manifest, to: workspace.manifestURL)
            throw error
        }
    }

    private func recognitionLocales(for languageMode: LanguageMode) -> [Locale] {
        let identifiers = languageMode == .japanese ? ["ja-JP"] : ["ja-JP", "en-US"]
        return identifiers.map(Locale.init(identifier:))
    }

    private func transcribe(
        manifest: RecordingManifest,
        workspace: RecordingWorkspacePaths,
        locales: [Locale]
    ) async throws -> [TimedTranscriptSegment] {
        var result: [TimedTranscriptSegment] = []
        var recentContextByTrack: [String: [String]] = [:]
        let chunks = manifest.chunks.sorted {
            if $0.startedAtMilliseconds == $1.startedAtMilliseconds {
                return $0.track.rawValue < $1.track.rawValue
            }
            return $0.startedAtMilliseconds < $1.startedAtMilliseconds
        }

        for chunk in chunks {
            let url = workspace.directory.appendingPathComponent(chunk.relativePath)
            guard fileManager.fileExists(atPath: url.path) else {
                throw PostProcessingError.missingAudio(chunk.relativePath)
            }

            let trackKey = chunk.track.rawValue
            let contextualStrings = [manifest.title] + (recentContextByTrack[trackKey] ?? [])
            var candidates: [RecognitionCandidate] = []
            var firstFailure: Error?
            for locale in locales {
                do {
                    let segments = try await recognitionEngine.recognize(
                        url: url,
                        locale: locale,
                        contextualStrings: contextualStrings
                    )
                    candidates.append(RecognitionCandidate(locale: locale, segments: segments))
                } catch {
                    firstFailure = firstFailure ?? error
                }
            }
            guard let best = candidates.filter({ !$0.segments.isEmpty }).max(by: { recognitionScore($0) < recognitionScore($1) }) else {
                if let firstFailure { throw firstFailure }
                continue
            }
            let contextText = TranscriptText.join(best.segments.map(\.text))
            if !contextText.isEmpty {
                var context = recentContextByTrack[trackKey] ?? []
                context.append(String(contextText.suffix(600)))
                recentContextByTrack[trackKey] = Array(context.suffix(3))
            }
            result.append(contentsOf: best.segments.map { segment in
                TimedTranscriptSegment(
                    startMilliseconds: chunk.startedAtMilliseconds + Int64(segment.startSeconds * 1_000),
                    endMilliseconds: chunk.startedAtMilliseconds + Int64((segment.startSeconds + segment.durationSeconds) * 1_000),
                    track: chunk.track,
                    language: best.locale.identifier.hasPrefix("ja") ? "ja" : "en",
                    text: segment.text, confidence: segment.confidence
                )
            })
        }
        return result.sorted {
            if $0.startMilliseconds == $1.startMilliseconds {
                return $0.track.rawValue < $1.track.rawValue
            }
            return $0.startMilliseconds < $1.startMilliseconds
        }
    }

    private func recognitionScore(_ candidate: RecognitionCandidate) -> Double {
        guard !candidate.segments.isEmpty else { return -.infinity }
        let confidence = TranscriptText.confidence(candidate.segments.map(\.confidence)) ?? 0.5
        let text = TranscriptText.join(candidate.segments.map(\.text))
        let boundedLengthBonus = Double(min(text.count, 100)) * 0.08
        let detectedLanguage = Self.language(of: text)
        let expectedLanguage = candidate.locale.identifier.hasPrefix("ja") ? "ja" : "en"
        let languageBonus = detectedLanguage == "und"
            ? 0
            : (detectedLanguage == expectedLanguage ? 20.0 : -20.0)
        return confidence * 100 + boundedLengthBonus + languageBonus
    }

    private func makeUtterances(
        from spans: [TimedTranscriptSegment],
        captureMode: CaptureMode,
        timelines: [AudioTrack: SpeakerTimeline]
    ) -> [UtteranceRecord] {
        TranscriptAssembler().assemble(segments: spans, captureMode: captureMode, timelines: timelines)
    }

    private func writeTranscriptArtifacts(
        workspace: RecordingWorkspacePaths, metadata: SessionMetadata, utterances: [UtteranceRecord]
    ) throws {
        let staging = workspace.directory.appendingPathComponent(".transcript-save-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: staging) }
        let json = staging.appendingPathComponent("transcript.jsonl")
        let markdown = staging.appendingPathComponent("transcript.md")
        try transcriptWriter.write(metadata: metadata, utterances: utterances, to: json)
        try markdownWriter.write(metadata: metadata, utterances: utterances, to: markdown)
        let location = SessionLocation(directory: workspace.directory)
        try ArtifactTransaction(fileManager: fileManager).commit(staged: [json, markdown], to: workspace.directory) {
            let saved = try self.transcriptWriter.read(from: location.transcriptJSONL, matching: metadata)
            guard saved.utterances == utterances else { throw PostProcessingError.incompleteArtifacts }
            try self.markdownWriter.validate(location.transcriptMarkdown, metadata: saved.metadata, utterances: saved.utterances)
        }
    }

    private static func language(of text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return switch recognizer.dominantLanguage {
        case .japanese: "ja"
        case .english: "en"
        default: "und"
        }
    }

    private static func date(from value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

private struct RecognitionCandidate: Sendable {
    let locale: Locale
    let segments: [RecognizedSegment]
}
