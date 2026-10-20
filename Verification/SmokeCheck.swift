import Foundation
import CaptureCore

@main
enum SmokeCheck {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw SmokeCheckError.missingOutputDirectory
        }

        let outputRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        guard let timezone = TimeZone(identifier: "Asia/Tokyo"),
              let startedAt = ISO8601DateFormatter().date(from: "2026-09-15T01:30:00Z"),
              let sessionID = UUID(uuidString: "A7F30000-0000-0000-0000-000000000000") else {
            throw SmokeCheckError.invalidFixture
        }

        let pathPolicy = SessionPathPolicy(timezone: timezone)
        let location = pathPolicy.location(
            under: outputRoot,
            startedAt: startedAt,
            title: "情報科学 / 第3回",
            sessionID: sessionID
        )
        guard location.directory.lastPathComponent == "2026-09-15_1030__情報科学-第3回__a7f3" else {
            throw SmokeCheckError.unexpectedSessionPath(location.directory.path)
        }

        let endedAt = startedAt.addingTimeInterval(90)
        let metadata = SessionMetadata(
            sessionID: sessionID,
            title: "情報科学 / 第3回",
            startedAt: startedAt,
            endedAt: endedAt,
            captureMode: .classroom,
            languageMode: .japaneseAndEnglish,
            timezone: timezone,
            appVersion: "0.1.0"
        )
        let utterances = [
            UtteranceRecord(
                index: 1,
                startMilliseconds: 1_000,
                endMilliseconds: 2_500,
                speaker: "speaker_01",
                track: .microphone,
                language: "ja",
                text: "今日の重要なポイントはデータの分類です。",
                confidence: 0.91
            ),
            UtteranceRecord(
                index: 2,
                startMilliseconds: 4_000,
                endMilliseconds: 6_500,
                speaker: "speaker_01",
                track: .microphone,
                language: "ja",
                text: "次回までの課題として具体例を確認してください。",
                confidence: 0.87
            )
        ]

        try pathPolicy.createDirectory(for: location)
        try TranscriptJSONLWriter().write(
            metadata: metadata,
            utterances: utterances,
            to: location.transcriptJSONL
        )

        let writtenData = try Data(contentsOf: location.transcriptJSONL)
        let lines = writtenData.split(separator: 0x0A)
        guard lines.count == 3,
              let record = try JSONSerialization.jsonObject(with: Data(lines[1])) as? [String: Any],
              record["type"] as? String == "utterance",
              record["confidence"] as? Double == 0.91 else {
            throw SmokeCheckError.invalidJSONL
        }

        try TranscriptMarkdownWriter().write(metadata: metadata, utterances: utterances, to: location.transcriptMarkdown)
        let decoded = try TranscriptJSONLWriter().read(from: location.transcriptJSONL)
        guard decoded.metadata == metadata, decoded.utterances == utterances else {
            throw SmokeCheckError.invalidJSONL
        }

        var stateMachine = SessionStateMachine()
        try stateMachine.transition(to: .recording)
        do {
            try stateMachine.transition(to: .transcribing)
            throw SmokeCheckError.invalidTransitionAccepted
        } catch SessionTransitionError.invalidTransition(from: .recording, to: .transcribing) {
            // Expected: finalization and speech detection cannot be skipped.
        }

        let workspaceRoot = outputRoot.appendingPathComponent("recordings", isDirectory: true)
        try RecordingStorageValidator().validate(root: workspaceRoot)
        let defaultsSuite = "RecallCaptureSmoke.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsSuite) else {
            throw SmokeCheckError.invalidFixture
        }
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let recentStore = RecentRecordingStore(defaults: defaults, key: "recent")
        recentStore.save(location.directory)
        guard recentStore.load() == location.directory.standardizedFileURL else {
            throw SmokeCheckError.invalidRecentRecordingPersistence
        }
        recentStore.clear()
        guard recentStore.load() == nil else {
            throw SmokeCheckError.invalidRecentRecordingPersistence
        }
        let workspace = RecordingWorkspacePaths(
            root: workspaceRoot,
            startedAt: startedAt,
            title: "情報科学 / 第3回",
            sessionID: sessionID,
            policy: pathPolicy
        )
        try workspace.createDirectories(tracks: [.system, .microphone])
        var manifest = RecordingManifest(
            sessionID: sessionID,
            title: "情報科学 / 第3回",
            captureMode: .meet,
            languageMode: .japaneseAndEnglish,
            startedAt: startedAt,
            tracks: [.system, .microphone]
        )
        manifest.append(AudioChunkDescriptor(
            index: 1,
            track: .system,
            relativePath: workspace.relativeCompletedChunkPath(track: .system, index: 1),
            startedAtMilliseconds: 0,
            durationMilliseconds: 60_000,
            byteCount: 42
        ))
        try RecordingManifestStore().save(manifest, to: workspace.manifestURL)
        guard RecordingRecoveryScanner().scan(root: workspaceRoot).first?.manifest == manifest else {
            throw SmokeCheckError.invalidRecordingManifest
        }

        let browserWindows = [
            BrowserWindowCandidate(
                id: 1, title: "Safari", applicationName: "Safari",
                bundleIdentifier: "com.apple.Safari", isOnScreen: true,
                width: 1200, height: 800
            ),
            BrowserWindowCandidate(
                id: 2, title: "Google Meet - 情報科学", applicationName: "Safari",
                bundleIdentifier: "com.apple.Safari", isOnScreen: true,
                width: 1200, height: 800
            ),
            BrowserWindowCandidate(
                id: 3, title: "Google Meet - 情報科学", applicationName: "Safari",
                bundleIdentifier: "com.apple.Safari", isOnScreen: true,
                width: 1200, height: 800
            ),
            BrowserWindowCandidate(
                id: 4, title: "Background", applicationName: "Google Chrome",
                bundleIdentifier: "com.google.Chrome", isOnScreen: false,
                width: 1200, height: 800
            ),
            BrowserWindowCandidate(
                id: 5, title: "Discord", applicationName: "Discord",
                bundleIdentifier: "com.hnc.Discord", isOnScreen: true,
                width: 1200, height: 800
            ),
            BrowserWindowCandidate(
                id: 6, title: "Zoom Meeting", applicationName: "zoom.us",
                bundleIdentifier: "us.zoom.xos", isOnScreen: true,
                width: 1200, height: 800
            )
        ]
        guard Set(BrowserWindowFilter.visibleUniqueWindows(from: browserWindows).map(\.id)) == Set([2, 5, 6]) else {
            throw SmokeCheckError.invalidBrowserWindowFiltering
        }

        let timeline = RTTMParser.parse("""
        SPEAKER session 1 0.00 1.20 <NA> <NA> speaker_01 <NA> <NA>
        SPEAKER session 1 1.20 1.80 <NA> <NA> speaker_02 <NA> <NA>
        SPEAKER session 1 2.90 0.50 <NA> <NA> speaker_03 <NA> <NA>
        """)
        guard timeline.segments.count == 3,
              timeline.speakerLabel(startMilliseconds: 1_300, endMilliseconds: 2_700) == "speaker_02",
              timeline.speakerLabel(startMilliseconds: 2_950, endMilliseconds: 3_100) == nil,
              timeline.speakerLabel(startMilliseconds: 900, endMilliseconds: 1_500) == nil else {
            throw SmokeCheckError.invalidSpeakerDiarization
        }

        print("smoke-check: passed")
        print(location.transcriptJSONL.path)
        print(location.transcriptMarkdown.path)
    }
}

enum SmokeCheckError: Error {
    case missingOutputDirectory
    case invalidFixture
    case unexpectedSessionPath(String)
    case invalidJSONL
    case invalidTransitionAccepted
    case invalidRecordingManifest
    case invalidBrowserWindowFiltering
    case invalidRecentRecordingPersistence
    case invalidSpeakerDiarization
}
