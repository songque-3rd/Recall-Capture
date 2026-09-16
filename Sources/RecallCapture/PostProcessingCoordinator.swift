@preconcurrency import Speech
import CaptureCore
import Foundation
import NaturalLanguage

enum PostProcessingError: LocalizedError {
    case invalidManifest
    case noAudioChunks
    case missingAudio(String)
    case speechPermissionDenied
    case speechPermissionRestricted
    case speechPermissionUnavailable
    case dictationDisabled
    case recognizerUnavailable(String)
    case onDeviceRecognitionUnavailable(String)
    case recognitionFailed(String)
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
        case .speechPermissionDenied:
            "音声認識が未許可です。システム設定の『音声認識』でRecall Captureをオンにしてから再開してください。"
        case .speechPermissionRestricted:
            "このMacでは音声認識の使用が制限されています。"
        case .speechPermissionUnavailable:
            "音声認識の許可状態を確認できませんでした。"
        case .dictationDisabled:
            "macOSの音声入力がオフです。システム設定 > キーボード > 音声入力をオンにしてから、後処理を再開してください。"
        case let .recognizerUnavailable(locale):
            "\(locale) の音声認識を現在利用できません。"
        case let .onDeviceRecognitionUnavailable(locale):
            "\(locale) の端末内音声認識がこのMacで利用できません。"
        case let .recognitionFailed(message):
            "音声認識に失敗しました: \(message)"
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
            try await authorizeSpeechRecognition()
            let locales = try recognizers(for: manifest.languageMode)

            await progress(.transcribing)
            let recognized = try await transcribe(
                manifest: manifest,
                workspace: workspace,
                recognizers: locales
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

    private func authorizeSpeechRecognition() async throws {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        switch status {
        case .authorized:
            return
        case .denied:
            throw PostProcessingError.speechPermissionDenied
        case .restricted:
            throw PostProcessingError.speechPermissionRestricted
        case .notDetermined:
            throw PostProcessingError.speechPermissionUnavailable
        @unknown default:
            throw PostProcessingError.speechPermissionUnavailable
        }
    }

    private func recognizers(for languageMode: LanguageMode) throws -> [SFSpeechRecognizer] {
        let identifiers = languageMode == .japanese ? ["ja-JP"] : ["ja-JP", "en-US"]
        return try identifiers.map { identifier in
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier)),
                  recognizer.isAvailable else {
                throw PostProcessingError.recognizerUnavailable(identifier)
            }
            guard recognizer.supportsOnDeviceRecognition else {
                throw PostProcessingError.onDeviceRecognitionUnavailable(identifier)
            }
            return recognizer
        }
    }

    private func transcribe(
        manifest: RecordingManifest,
        workspace: RecordingWorkspacePaths,
        recognizers: [SFSpeechRecognizer]
    ) async throws -> [RecognizedSpan] {
        var result: [RecognizedSpan] = []
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

            var candidates: [[RecognizedSegment]] = []
            for recognizer in recognizers {
                let segments = try await recognize(url: url, with: recognizer)
                candidates.append(segments)
            }
            guard let best = candidates.max(by: { recognitionScore($0) < recognitionScore($1) }) else {
                continue
            }
            result.append(contentsOf: group(
                best,
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

    private func recognize(
        url: URL,
        with recognizer: SFSpeechRecognizer
    ) async throws -> [RecognizedSegment] {
        try await withCheckedThrowingContinuation { continuation in
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = false
            request.addsPunctuation = true
            let gate = RecognitionGate(continuation: continuation)
            gate.task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    gate.finish(.success(result.bestTranscription.segments.map {
                        RecognizedSegment(
                            text: $0.substring,
                            startSeconds: $0.timestamp,
                            durationSeconds: $0.duration,
                            confidence: Double($0.confidence)
                        )
                    }))
                } else if let error {
                    let recognitionError = error as NSError
                    let normalizedMessage = recognitionError.localizedDescription.lowercased()
                    if recognitionError.code == 1_110 {
                        gate.finish(.success([]))
                    } else if normalizedMessage.contains("dictation")
                        && normalizedMessage.contains("disabled") {
                        gate.finish(.failure(PostProcessingError.dictationDisabled))
                    } else {
                        gate.finish(.failure(PostProcessingError.recognitionFailed(error.localizedDescription)))
                    }
                }
            }
        }
    }

    private func recognitionScore(_ segments: [RecognizedSegment]) -> Double {
        guard !segments.isEmpty else { return 0 }
        let confidence = segments.map(\.confidence).reduce(0, +) / Double(segments.count)
        let characters = segments.reduce(0) { $0 + $1.text.count }
        return confidence * 100 + Double(characters)
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

private struct RecognizedSegment: Sendable {
    let text: String
    let startSeconds: TimeInterval
    let durationSeconds: TimeInterval
    let confidence: Double
}

private struct RecognizedSpan: Sendable {
    let startMilliseconds: Int64
    let endMilliseconds: Int64
    let track: AudioTrack
    let language: String
    let text: String
    let confidence: Double
}

private final class RecognitionGate: @unchecked Sendable {
    var task: SFSpeechRecognitionTask?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[RecognizedSegment], Error>?

    init(continuation: CheckedContinuation<[RecognizedSegment], Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<[RecognizedSegment], Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        task = nil
        lock.unlock()

        switch result {
        case let .success(value): continuation.resume(returning: value)
        case let .failure(error): continuation.resume(throwing: error)
        }
    }
}
