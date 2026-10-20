import Foundation
import Testing
@testable import CaptureCore

@Suite("CaptureCore")
struct CaptureCoreTests {
    @Test("年・月・セッションの保存構造を生成する")
    func sessionLocation() throws {
        let timezone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let policy = SessionPathPolicy(timezone: timezone)
        let date = try #require(ISO8601DateFormatter().date(from: "2026-09-15T01:30:00Z"))
        let id = try #require(UUID(uuidString: "A7F30000-0000-0000-0000-000000000000"))

        let location = policy.location(
            under: URL(fileURLWithPath: "/output"),
            startedAt: date,
            title: "情報科学 / 第3回",
            sessionID: id
        )

        #expect(location.directory.path == "/output/2026/2026-09/2026-09-15_1030__情報科学-第3回__a7f3")
        #expect(location.transcriptJSONL.lastPathComponent == "transcript.jsonl")
    }

    @Test("JSONLを仕様どおり生成して読み戻せる")
    func writesJSONL() throws {
        let timezone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let startedAt = Date(timeIntervalSince1970: 1_789_425_000)
        let metadata = SessionMetadata(
            sessionID: UUID(),
            title: "テスト講義",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(90),
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
                text: "テストです。",
                confidence: nil
            )
        ]

        let data = try TranscriptJSONLWriter().data(
            metadata: metadata,
            utterances: utterances
        )
        let lines = data.split(separator: 0x0A)
        #expect(lines.count == 2)

        let first = try #require(
            JSONSerialization.jsonObject(with: Data(lines[0])) as? [String: Any]
        )
        let second = try #require(
            JSONSerialization.jsonObject(with: Data(lines[1])) as? [String: Any]
        )
        #expect(first["type"] as? String == "session")
        #expect(first["language_mode"] as? String == "ja-en")
        #expect(second["type"] as? String == "utterance")
        #expect(second.keys.contains("confidence"))
        #expect(second["confidence"] is NSNull)
    }

    @Test("時刻が逆行する発話を拒否する")
    func rejectsTimestampRegression() throws {
        let metadata = SessionMetadata(
            sessionID: UUID(),
            title: "テスト",
            startedAt: .now,
            endedAt: .now,
            captureMode: .meet,
            languageMode: .japanese,
            timezone: .current,
            appVersion: "0.1.0"
        )
        let utterances = [
            UtteranceRecord(
                index: 1,
                startMilliseconds: 2_000,
                endMilliseconds: 3_000,
                speaker: "self",
                track: .microphone,
                language: "ja",
                text: "一つ目",
                confidence: 0.9
            ),
            UtteranceRecord(
                index: 2,
                startMilliseconds: 1_000,
                endMilliseconds: 1_500,
                speaker: "speaker_01",
                track: .system,
                language: "ja",
                text: "二つ目",
                confidence: 0.8
            )
        ]

        #expect(throws: TranscriptValidationError.timestampRegression(index: 2)) {
            try TranscriptJSONLWriter().data(metadata: metadata, utterances: utterances)
        }
    }

    @Test("処理段階を飛ばせない")
    func stateTransitions() throws {
        var machine = SessionStateMachine()
        try machine.transition(to: .recording)
        #expect(machine.state == .recording)
        #expect(throws: SessionTransitionError.invalidTransition(from: .recording, to: .transcribing)) {
            try machine.transition(to: .transcribing)
        }
    }

    @Test("録音マニフェストを保存し復旧候補として検出する")
    func recordingRecovery() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_789_425_000)
        let paths = RecordingWorkspacePaths(
            root: root,
            startedAt: startedAt,
            title: "復旧テスト",
            sessionID: sessionID,
            policy: SessionPathPolicy(timezone: try #require(TimeZone(identifier: "Asia/Tokyo")))
        )
        try paths.createDirectories(tracks: [.system, .microphone])
        var manifest = RecordingManifest(
            sessionID: sessionID,
            title: "復旧テスト",
            captureMode: .meet,
            languageMode: .japanese,
            startedAt: startedAt,
            tracks: [.system, .microphone]
        )
        manifest.append(AudioChunkDescriptor(
            index: 1,
            track: .system,
            relativePath: paths.relativeCompletedChunkPath(track: .system, index: 1),
            startedAtMilliseconds: 0,
            durationMilliseconds: 60_000,
            byteCount: 123
        ))
        try RecordingManifestStore().save(manifest, to: paths.manifestURL)

        let candidates = RecordingRecoveryScanner().scan(root: root)
        #expect(candidates.count == 1)
        #expect(candidates.first?.manifest.sessionID == sessionID.uuidString.lowercased())
        #expect(candidates.first?.manifest.chunks.first?.durationMilliseconds == 60_000)
    }

    @Test("旧式の直下セッションも復旧候補として検出する")
    func legacyRecordingRecovery() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = UUID()
        let paths = RecordingWorkspacePaths(root: root, sessionID: sessionID)
        try paths.createDirectories(tracks: [.microphone])
        let manifest = RecordingManifest(
            sessionID: sessionID,
            title: "旧式",
            captureMode: .classroom,
            languageMode: .japanese,
            startedAt: .now,
            tracks: [.microphone]
        )
        try RecordingManifestStore().save(manifest, to: paths.manifestURL)

        let candidates = RecordingRecoveryScanner().scan(root: root)
        #expect(candidates.map(\.manifest.sessionID) == [sessionID.uuidString.lowercased()])
    }

    @Test("保存先を永続化し標準へ戻せる")
    func destinationPersistence() throws {
        let suiteName = "RecallCaptureTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RecordingDestinationStore(defaults: defaults, key: "destination")
        let fallback = URL(fileURLWithPath: "/fallback", isDirectory: true)
        let selected = URL(fileURLWithPath: "/selected/recordings", isDirectory: true)

        #expect(store.load(defaultURL: fallback).path == fallback.path)
        store.save(selected)
        #expect(store.load(defaultURL: fallback).path == selected.path)
        store.clear()
        #expect(store.load(defaultURL: fallback).path == fallback.path)
    }

    @Test("直近セッションを次回起動用に永続化できる")
    func recentRecordingPersistence() throws {
        let suiteName = "RecallCaptureTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RecentRecordingStore(defaults: defaults, key: "recent")
        let workspace = URL(fileURLWithPath: "/recordings/2026/2026-09/session", isDirectory: true)

        #expect(store.load() == nil)
        store.save(workspace)
        #expect(store.load()?.path == workspace.path)
        store.clear()
        #expect(store.load() == nil)
    }

    @Test("保存先へ実際に書き込めることを検証する")
    func destinationValidation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try RecordingStorageValidator().validate(root: root)
        #expect(FileManager.default.fileExists(atPath: root.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(leftovers.isEmpty)

        let file = root.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: file)
        #expect(throws: RecordingStorageValidationError.pathIsNotDirectory(file.path)) {
            try RecordingStorageValidator().validate(root: file)
        }
    }

    @Test("オンライン会議候補から不要なウインドウを除外し、DiscordとZoomを含める")
    func browserWindowFiltering() {
        let windows = [
            BrowserWindowCandidate(
                id: 1, title: "Google Meet - 講義", applicationName: "Safari",
                bundleIdentifier: "com.apple.Safari", isOnScreen: true, width: 1200, height: 800
            ),
            BrowserWindowCandidate(
                id: 2, title: "Google Meet - 講義", applicationName: "Safari",
                bundleIdentifier: "com.apple.Safari", isOnScreen: true, width: 1200, height: 800
            ),
            BrowserWindowCandidate(
                id: 3, title: "", applicationName: "Safari",
                bundleIdentifier: "com.apple.Safari", isOnScreen: true, width: 1200, height: 800
            ),
            BrowserWindowCandidate(
                id: 4, title: "Background", applicationName: "Safari",
                bundleIdentifier: "com.apple.Safari", isOnScreen: false, width: 1200, height: 800
            ),
            BrowserWindowCandidate(
                id: 5, title: "Tiny", applicationName: "Chrome",
                bundleIdentifier: "com.google.Chrome", isOnScreen: true, width: 100, height: 80
            ),
            BrowserWindowCandidate(
                id: 6, title: "Notes", applicationName: "Chrome",
                bundleIdentifier: "com.google.Chrome", isOnScreen: true, width: 1000, height: 700
            ),
            BrowserWindowCandidate(
                id: 7, title: "Meet", applicationName: "Other",
                bundleIdentifier: "example.unsupported", isOnScreen: true, width: 1000, height: 700
            ),
            BrowserWindowCandidate(
                id: 8, title: "Safari helper", applicationName: "Safari",
                bundleIdentifier: "com.apple.Safari", isOnScreen: true, windowLayer: 3,
                width: 1000, height: 700
            ),
            BrowserWindowCandidate(
                id: 9, title: "Safari", applicationName: "Safari",
                bundleIdentifier: "com.apple.Safari", isOnScreen: true,
                width: 1000, height: 700
            ),
            BrowserWindowCandidate(
                id: 10, title: "Google Chrome", applicationName: "Google Chrome",
                bundleIdentifier: "com.google.Chrome", isOnScreen: true,
                width: 1000, height: 700
            ),
            BrowserWindowCandidate(
                id: 11, title: "Discord", applicationName: "Discord",
                bundleIdentifier: "com.hnc.Discord", isOnScreen: true,
                width: 1000, height: 700
            ),
            BrowserWindowCandidate(
                id: 12, title: "Zoom Meeting", applicationName: "zoom.us",
                bundleIdentifier: "us.zoom.xos", isOnScreen: true,
                width: 1000, height: 700
            )
        ]

        let filtered = BrowserWindowFilter.visibleUniqueWindows(from: windows)
        #expect(Set(filtered.map(\.id)) == Set([1, 6, 11, 12]))
        #expect(Set(filtered.prefix(3).map(\.id)) == Set([1, 11, 12]))
    }

    @Test("RTTMを匿名話者タイムラインへ変換する")
    func parsesRTTM() throws {
        let timeline = RTTMParser.parse("""
        SPEAKER recording 1 0.500 1.000 <NA> <NA> speaker_2 <NA> <NA>
        SPEAKER recording 1 1.500 0.500 <NA> <NA> speaker_2 <NA> <NA>
        SPEAKER recording 1 invalid 0.500 <NA> <NA> speaker_3 <NA> <NA>
        """)

        #expect(timeline.segments.count == 2)
        #expect(timeline.speakerLabel(startMilliseconds: 400, endMilliseconds: 2_100) == "speaker_02")
    }

    @Test("複数話者が重なる発話はunknownへ倒す")
    func rejectsOverlappingSpeakers() {
        let timeline = SpeakerTimeline(segments: [
            SpeakerActivitySegment(startMilliseconds: 0, endMilliseconds: 1_000, speakerNumber: 1),
            SpeakerActivitySegment(startMilliseconds: 800, endMilliseconds: 1_600, speakerNumber: 2),
        ])

        #expect(timeline.speakerLabel(startMilliseconds: 400, endMilliseconds: 1_200) == nil)
    }

    @Test("話者根拠が短すぎる発話はunknownへ倒す")
    func rejectsSparseSpeakerEvidence() {
        let timeline = SpeakerTimeline(segments: [
            SpeakerActivitySegment(startMilliseconds: 0, endMilliseconds: 80, speakerNumber: 1),
        ])

        #expect(timeline.speakerLabel(startMilliseconds: 0, endMilliseconds: 1_000) == nil)
    }
}
