import CaptureCore
import Foundation

@main
struct SpeechRecognitionSmokeCheck {
    static func main() async throws {
        guard CommandLine.arguments.count >= 2 else {
            fputs("usage: speech-recognition-smoke <audio-file> [locale]\n", stderr)
            exit(64)
        }

        let audioURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let locale = Locale(identifier: CommandLine.arguments.count >= 3 ? CommandLine.arguments[2] : "ja-JP")
        let engine = SpeechRecognitionEngine()
        try await engine.authorize()
        let segments = try await engine.recognize(
            url: audioURL,
            locale: locale,
            contextualStrings: []
        )

        let characterCount = segments.reduce(0) { $0 + $1.text.count }
        let averageConfidence = TranscriptText.confidence(segments.map(\.confidence))
        let recognizedDuration = segments.reduce(0.0) { $0 + $1.durationSeconds }

        print("speech-recognition-smoke: passed")
        print("segments=\(segments.count)")
        print("characters=\(characterCount)")
        print(averageConfidence.map { String(format: "averageConfidence=%.3f", $0) } ?? "averageConfidence=unavailable")
        print(String(format: "recognizedDuration=%.3f", recognizedDuration))
    }
}
