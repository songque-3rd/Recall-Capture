@preconcurrency import Speech
import AVFoundation
import CoreMedia
import Foundation

enum SpeechRecognitionEngineError: LocalizedError {
    case permissionDenied
    case permissionRestricted
    case permissionUnavailable
    case dictationDisabled
    case recognizerUnavailable(String)
    case onDeviceRecognitionUnavailable(String)
    case modelInstallationFailed(String)
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "音声認識が未許可です。システム設定の『音声認識』でRecall Captureをオンにしてから再開してください。"
        case .permissionRestricted:
            "このMacでは音声認識の使用が制限されています。"
        case .permissionUnavailable:
            "音声認識の許可状態を確認できませんでした。"
        case .dictationDisabled:
            "macOSの音声入力がオフです。システム設定 > キーボード > 音声入力をオンにしてから、後処理を再開してください。"
        case let .recognizerUnavailable(locale):
            "\(locale) の音声認識を現在利用できません。"
        case let .onDeviceRecognitionUnavailable(locale):
            "\(locale) の端末内音声認識がこのMacで利用できません。"
        case let .modelInstallationFailed(locale):
            "\(locale) の端末内音声認識モデルを準備できませんでした。ネットワーク接続を確認して再処理してください。"
        case let .recognitionFailed(message):
            "音声認識に失敗しました: \(message)"
        }
    }
}

struct RecognizedSegment: Sendable {
    let text: String
    let startSeconds: TimeInterval
    let durationSeconds: TimeInterval
    let confidence: Double
}

final class SpeechRecognitionEngine: @unchecked Sendable {
    func authorize() async throws {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        switch status {
        case .authorized:
            return
        case .denied:
            throw SpeechRecognitionEngineError.permissionDenied
        case .restricted:
            throw SpeechRecognitionEngineError.permissionRestricted
        case .notDetermined:
            throw SpeechRecognitionEngineError.permissionUnavailable
        @unknown default:
            throw SpeechRecognitionEngineError.permissionUnavailable
        }
    }

    func recognize(
        url: URL,
        locale requestedLocale: Locale,
        contextualStrings: [String]
    ) async throws -> [RecognizedSegment] {
        if #available(macOS 26.0, *), SpeechTranscriber.isAvailable,
           let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) {
            do {
                return try await recognizeWithSpeechAnalyzer(
                    url: url,
                    locale: supportedLocale,
                    contextualStrings: contextualStrings
                )
            } catch {
                // A locale can be reported as supported while its asset is not
                // usable on a particular OS build. Preserve a fully local path.
                return try await recognizeWithLegacyRecognizer(
                    url: url,
                    locale: requestedLocale,
                    contextualStrings: contextualStrings
                )
            }
        }
        return try await recognizeWithLegacyRecognizer(
            url: url,
            locale: requestedLocale,
            contextualStrings: contextualStrings
        )
    }

    @available(macOS 26.0, *)
    private func recognizeWithSpeechAnalyzer(
        url: URL,
        locale: Locale,
        contextualStrings: [String]
    ) async throws -> [RecognizedSegment] {
        // The transcription preset requests the complete, highest-quality
        // result without lower-accuracy volatile or fast output.
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        try await installAssetsIfNeeded(for: transcriber, locale: locale)

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw SpeechRecognitionEngineError.recognitionFailed(error.localizedDescription)
        }

        let context = AnalysisContext()
        let cleanedContext = contextualStrings
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .suffix(4)
        if !cleanedContext.isEmpty {
            context.contextualStrings[.general] = Array(cleanedContext)
        }

        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: .init(priority: .userInitiated, modelRetention: .lingering)
        )
        do {
            try await analyzer.setContext(context)
        } catch {
            throw SpeechRecognitionEngineError.recognitionFailed(error.localizedDescription)
        }

        let resultTask = Task { try await Self.collectFinalResults(from: transcriber) }
        do {
            if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            return try await resultTask.value
        } catch {
            await analyzer.cancelAndFinishNow()
            resultTask.cancel()
            throw SpeechRecognitionEngineError.recognitionFailed(error.localizedDescription)
        }
    }

    @available(macOS 26.0, *)
    private func installAssetsIfNeeded(
        for transcriber: SpeechTranscriber,
        locale: Locale
    ) async throws {
        let modules: [any SpeechModule] = [transcriber]
        switch await AssetInventory.status(forModules: modules) {
        case .installed:
            return
        case .unsupported:
            throw SpeechRecognitionEngineError.onDeviceRecognitionUnavailable(locale.identifier)
        case .supported, .downloading:
            do {
                guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else {
                    throw SpeechRecognitionEngineError.modelInstallationFailed(locale.identifier)
                }
                try await request.downloadAndInstall()
                guard await AssetInventory.status(forModules: modules) == .installed else {
                    throw SpeechRecognitionEngineError.modelInstallationFailed(locale.identifier)
                }
            } catch let error as SpeechRecognitionEngineError {
                throw error
            } catch {
                throw SpeechRecognitionEngineError.modelInstallationFailed(locale.identifier)
            }
        @unknown default:
            throw SpeechRecognitionEngineError.modelInstallationFailed(locale.identifier)
        }
    }

    @available(macOS 26.0, *)
    private static func collectFinalResults(
        from transcriber: SpeechTranscriber
    ) async throws -> [RecognizedSegment] {
        var output: [RecognizedSegment] = []
        for try await result in transcriber.results {
            let text = String(result.text.characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let confidences = result.text.runs.compactMap(\.transcriptionConfidence)
            let confidence = confidences.isEmpty
                ? 0.5
                : confidences.reduce(0, +) / Double(confidences.count)
            output.append(RecognizedSegment(
                text: text,
                startSeconds: max(0, CMTimeGetSeconds(result.range.start)),
                durationSeconds: max(0, CMTimeGetSeconds(result.range.duration)),
                confidence: min(1, max(0, confidence))
            ))
        }
        return output
    }

    private func recognizeWithLegacyRecognizer(
        url: URL,
        locale: Locale,
        contextualStrings: [String]
    ) async throws -> [RecognizedSegment] {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw SpeechRecognitionEngineError.recognizerUnavailable(locale.identifier)
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw SpeechRecognitionEngineError.onDeviceRecognitionUnavailable(locale.identifier)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = false
            request.addsPunctuation = true
            request.contextualStrings = Array(contextualStrings.suffix(4))
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
                        gate.finish(.failure(SpeechRecognitionEngineError.dictationDisabled))
                    } else {
                        gate.finish(.failure(
                            SpeechRecognitionEngineError.recognitionFailed(error.localizedDescription)
                        ))
                    }
                }
            }
        }
    }
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
