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
            "文字起こしJSONLと要約PDFの両方を確定できませんでした。"
        }
    }
}

struct PostProcessingResult: Sendable {
    let workspace: RecordingWorkspacePaths
    let transcriptURL: URL
    let summaryPDFURL: URL
    let utteranceCount: Int
}

final class PostProcessingCoordinator: @unchecked Sendable {
    typealias ProgressHandler = @Sendable (SessionState) async -> Void

    private let fileManager: FileManager
    private let manifestStore = RecordingManifestStore()
    private let transcriptWriter = TranscriptJSONLWriter()
    private let summaryBuilder = LocalSummaryBuilder()
    private let pdfWriter = SummaryPDFWriter()
    private let recognitionEngine = SpeechRecognitionEngine()

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

            await progress(.detectingSpeech)
            try await recognitionEngine.authorize()
            let locales = recognitionLocales(for: manifest.languageMode)

            await progress(.transcribing)
            let recognized = try await transcribe(
                manifest: manifest,
                workspace: workspace,
                locales: locales
            )
            guard !recognized.isEmpty else {
                throw PostProcessingError.noSpeechDetected
            }

            await progress(.diarizing)
            let utterances = makeUtterances(from: recognized, captureMode: manifest.captureMode)

            await progress(.formatting)
            guard let sessionID = UUID(uuidString: manifest.sessionID),
                  let startedAt = Self.date(from: manifest.startedAt) else {
                throw PostProcessingError.invalidManifest
            }
            let durationMilliseconds = manifest.chunks.map {
                $0.startedAtMilliseconds + $0.durationMilliseconds
            }.max() ?? 0
            let metadata = SessionMetadata(
                sessionID: sessionID,
                title: manifest.title,
                startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(Double(durationMilliseconds) / 1_000),
                captureMode: manifest.captureMode,
                languageMode: manifest.languageMode,
                timezone: .current,
                appVersion: appVersion
            )

            await progress(.summarizingChunks)
            let summary = summaryBuilder.build(metadata: metadata, utterances: utterances)
            await progress(.summarizingOverall)

            await progress(.writingArtifacts)
            let artifacts = try writeArtifactPair(
                workspace: workspace,
                metadata: metadata,
                utterances: utterances,
                summary: summary
            )

            await progress(.validatingArtifacts)
            try validateArtifactPair(
                transcriptURL: artifacts.transcript,
                summaryPDFURL: artifacts.pdf
            )

            manifest.setStatus(.completed)
            try manifestStore.save(manifest, to: workspace.manifestURL)
            return PostProcessingResult(
                workspace: workspace,
                transcriptURL: artifacts.transcript,
                summaryPDFURL: artifacts.pdf,
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
    ) async throws -> [RecognizedSpan] {
        var result: [RecognizedSpan] = []
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
            guard let best = candidates.max(by: { recognitionScore($0) < recognitionScore($1) }) else {
                if let firstFailure { throw firstFailure }
                continue
            }
            let contextText = best.segments.map(\.text).joined(separator: " ")
            if !contextText.isEmpty {
                var context = recentContextByTrack[trackKey] ?? []
                context.append(String(contextText.suffix(600)))
                recentContextByTrack[trackKey] = Array(context.suffix(3))
            }
            result.append(contentsOf: group(
                best.segments,
                chunkOffsetMilliseconds: chunk.startedAtMilliseconds,
                track: chunk.track
            ))
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
        let confidence = candidate.segments.map(\.confidence).reduce(0, +)
            / Double(candidate.segments.count)
        let text = candidate.segments.map(\.text).joined(separator: " ")
        let boundedLengthBonus = Double(min(text.count, 100)) * 0.08
        let detectedLanguage = Self.language(of: text)
        let expectedLanguage = candidate.locale.identifier.hasPrefix("ja") ? "ja" : "en"
        let languageBonus = detectedLanguage == "und"
            ? 0
            : (detectedLanguage == expectedLanguage ? 20.0 : -20.0)
        return confidence * 100 + boundedLengthBonus + languageBonus
    }

    private func group(
        _ segments: [RecognizedSegment],
        chunkOffsetMilliseconds: Int64,
        track: AudioTrack
    ) -> [RecognizedSpan] {
        var output: [RecognizedSpan] = []
        var current: [RecognizedSegment] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined(separator: " ")
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                current.removeAll(keepingCapacity: true)
                return
            }
            output.append(RecognizedSpan(
                startMilliseconds: chunkOffsetMilliseconds + Int64(first.startSeconds * 1_000),
                endMilliseconds: chunkOffsetMilliseconds + Int64((last.startSeconds + last.durationSeconds) * 1_000),
                track: track,
                language: Self.language(of: text),
                text: text,
                confidence: current.map(\.confidence).reduce(0, +) / Double(current.count)
            ))
            current.removeAll(keepingCapacity: true)
        }

        for segment in segments {
            if let prior = current.last {
                let gap = segment.startSeconds - (prior.startSeconds + prior.durationSeconds)
                let elapsed = segment.startSeconds - (current.first?.startSeconds ?? segment.startSeconds)
                if gap > 1.2 || elapsed > 15 {
                    flush()
                }
            }
            current.append(segment)
            if segment.text.last.map({ "。！？.!?".contains($0) }) == true {
                flush()
            }
        }
        flush()
        return output
    }

    private func makeUtterances(
        from spans: [RecognizedSpan],
        captureMode: CaptureMode
    ) -> [UtteranceRecord] {
        spans.enumerated().map { offset, span in
            let speaker: String
            if captureMode == .classroom {
                speaker = "unknown"
            } else {
                speaker = span.track == .microphone ? "self" : "speaker_01"
            }
            return UtteranceRecord(
                index: offset + 1,
                startMilliseconds: span.startMilliseconds,
                endMilliseconds: max(span.startMilliseconds, span.endMilliseconds),
                speaker: speaker,
                track: span.track,
                language: span.language,
                text: span.text,
                confidence: min(1, max(0, span.confidence))
            )
        }
    }

    private func writeArtifactPair(
        workspace: RecordingWorkspacePaths,
        metadata: SessionMetadata,
        utterances: [UtteranceRecord],
        summary: SessionSummary
    ) throws -> (transcript: URL, pdf: URL) {
        let location = SessionLocation(directory: workspace.directory)
        let staging = workspace.directory.appendingPathComponent(
            ".postprocessing-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: staging) }

        let stagedTranscript = staging.appendingPathComponent("transcript.jsonl")
        let stagedPDF = staging.appendingPathComponent("summary.pdf")
        try transcriptWriter.write(metadata: metadata, utterances: utterances, to: stagedTranscript)
        try pdfWriter.write(summary: summary, metadata: metadata, to: stagedPDF)
        try validateArtifactPair(transcriptURL: stagedTranscript, summaryPDFURL: stagedPDF)

        try replacePair(
            stagedTranscript: stagedTranscript,
            stagedPDF: stagedPDF,
            destinationTranscript: location.transcriptJSONL,
            destinationPDF: location.summaryPDF
        )
        return (location.transcriptJSONL, location.summaryPDF)
    }

    private func replacePair(
        stagedTranscript: URL,
        stagedPDF: URL,
        destinationTranscript: URL,
        destinationPDF: URL
    ) throws {
        let backupTranscript = destinationTranscript.appendingPathExtension("backup")
        let backupPDF = destinationPDF.appendingPathExtension("backup")
        try? fileManager.removeItem(at: backupTranscript)
        try? fileManager.removeItem(at: backupPDF)

        if fileManager.fileExists(atPath: destinationTranscript.path) {
            try fileManager.moveItem(at: destinationTranscript, to: backupTranscript)
        }
        if fileManager.fileExists(atPath: destinationPDF.path) {
            try fileManager.moveItem(at: destinationPDF, to: backupPDF)
        }

        do {
            try fileManager.moveItem(at: stagedTranscript, to: destinationTranscript)
            try fileManager.moveItem(at: stagedPDF, to: destinationPDF)
            try validateArtifactPair(
                transcriptURL: destinationTranscript,
                summaryPDFURL: destinationPDF
            )
            try? fileManager.removeItem(at: backupTranscript)
            try? fileManager.removeItem(at: backupPDF)
        } catch {
            try? fileManager.removeItem(at: destinationTranscript)
            try? fileManager.removeItem(at: destinationPDF)
            if fileManager.fileExists(atPath: backupTranscript.path) {
                try? fileManager.moveItem(at: backupTranscript, to: destinationTranscript)
            }
            if fileManager.fileExists(atPath: backupPDF.path) {
                try? fileManager.moveItem(at: backupPDF, to: destinationPDF)
            }
            throw error
        }
    }

    private func validateArtifactPair(transcriptURL: URL, summaryPDFURL: URL) throws {
        guard fileManager.fileExists(atPath: transcriptURL.path),
              fileManager.fileExists(atPath: summaryPDFURL.path),
              let transcriptData = try? Data(contentsOf: transcriptURL),
              !transcriptData.isEmpty,
              !transcriptData.split(separator: 0x0A).isEmpty else {
            throw PostProcessingError.incompleteArtifacts
        }
        try pdfWriter.validate(summaryPDFURL, fileManager: fileManager)
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

private struct RecognizedSpan: Sendable {
    let startMilliseconds: Int64
    let endMilliseconds: Int64
    let track: AudioTrack
    let language: String
    let text: String
    let confidence: Double
}
