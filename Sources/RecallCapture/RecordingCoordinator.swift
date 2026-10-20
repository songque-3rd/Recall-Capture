import CaptureCore
import CoreMedia
import Foundation

struct RecordingResult: Sendable {
    let workspace: RecordingWorkspacePaths
    let manifest: RecordingManifest
}

enum RecordingCoordinatorError: LocalizedError {
    case recordingFailed(String)

    var errorDescription: String? {
        switch self {
        case let .recordingFailed(message): message
        }
    }
}

final class RecordingCoordinator: @unchecked Sendable {
    typealias FailureHandler = @Sendable (String) -> Void

    static let chunkDurationSeconds = 60

    private let captureQueue = DispatchQueue(label: "jp.recallcapture.audio-samples")
    private let controlQueue = DispatchQueue(label: "jp.recallcapture.capture-control")
    private let manifestStore = RecordingManifestStore()
    private var workspaceRoot: URL
    private let failureHandler: FailureHandler

    private var meetEngine: MeetCaptureEngine?
    private var classroomEngine: ClassroomCaptureEngine?

    // The following properties are confined to captureQueue.
    private var workspace: RecordingWorkspacePaths?
    private var manifest: RecordingManifest?
    private var writers: [AudioTrack: ChunkedAudioWriter] = [:]
    private var configuredMaximumSeconds = RecordingLimit.defaultSeconds
    private var inputLevels: [AudioTrack: AudioInputSnapshot] = [:]
    private var timelineOriginSeconds: Double?
    private var acceptsSamples = false
    private var didReportFailure = false

    init(
        workspaceRoot: URL = RecordingCoordinator.defaultWorkspaceRoot(),
        failureHandler: @escaping FailureHandler
    ) {
        self.workspaceRoot = workspaceRoot
        self.failureHandler = failureHandler
    }

    static func defaultWorkspaceRoot(fileManager: FileManager = .default) -> URL {
        let applicationSupport = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("RecallCapture", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    static func recoveryCandidates(
        workspaceRoot: URL = RecordingCoordinator.defaultWorkspaceRoot()
    ) -> [RecordingRecoveryCandidate] {
        RecordingRecoveryScanner().scan(root: workspaceRoot)
    }

    func updateWorkspaceRoot(_ workspaceRoot: URL) throws {
        try captureQueue.sync {
            guard manifest == nil else { throw AudioCaptureError.alreadyRecording }
            self.workspaceRoot = workspaceRoot.standardizedFileURL
        }
    }

    func startMeet(
        windowID: CGWindowID,
        microphoneDeviceID: String?,
        title: String,
        languageMode: LanguageMode
    ) async throws -> RecordingWorkspacePaths {
        let paths = try prepare(
            title: title,
            mode: .meet,
            languageMode: languageMode,
            tracks: [.system, .microphone]
        )
        let engine = MeetCaptureEngine(
            captureQueue: captureQueue,
            sampleHandler: { [weak self] track, sampleBuffer in
                self?.consume(sampleBuffer, track: track)
            },
            failureHandler: { [weak self] error in
                guard let self else { return }
                self.captureQueue.async {
                    self.recordFailure("システム音声の取得が停止しました: \(error.localizedDescription)")
                }
            }
        )
        meetEngine = engine
        do {
            try await engine.start(
                windowID: windowID,
                microphoneDeviceID: microphoneDeviceID
            )
            return paths
        } catch {
            try? await engine.stop()
            meetEngine = nil
            captureQueue.sync {
                recordFailure("オンライン会議の録音を開始できませんでした: \(error.localizedDescription)")
            }
            _ = try? await stop()
            throw error
        }
    }

    func startClassroom(
        microphoneDeviceID: String?,
        title: String,
        languageMode: LanguageMode
    ) async throws -> RecordingWorkspacePaths {
        let paths = try prepare(
            title: title,
            mode: .classroom,
            languageMode: languageMode,
            tracks: [.microphone]
        )
        let engine = ClassroomCaptureEngine(
            captureQueue: captureQueue,
            sampleHandler: { [weak self] track, sampleBuffer in
                self?.consume(sampleBuffer, track: track)
            }
        )
        classroomEngine = engine
        do {
            try await withCheckedThrowingContinuation { continuation in
                controlQueue.async {
                    do {
                        try engine.start(deviceID: microphoneDeviceID)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            return paths
        } catch {
            classroomEngine = nil
            captureQueue.sync {
                recordFailure("対面録音を開始できませんでした: \(error.localizedDescription)")
            }
            _ = try? await stop()
            throw error
        }
    }

    func stop() async throws -> RecordingResult {
        var preservedFailure: String?
        try captureQueue.sync {
            guard manifest != nil else { throw AudioCaptureError.notRecording }
            acceptsSamples = false
            if manifest?.status == .failed {
                preservedFailure = manifest?.lastError ?? "録音中にエラーが発生しました。"
            } else {
                manifest?.setStatus(.finalizing)
            }
            try saveManifest()
        }

        var stopError: Error?
        if let meetEngine {
            do {
                try await meetEngine.stop()
            } catch {
                stopError = error
            }
            self.meetEngine = nil
        }
        if let classroomEngine {
            await withCheckedContinuation { continuation in
                controlQueue.async {
                    classroomEngine.stop()
                    continuation.resume()
                }
            }
            self.classroomEngine = nil
        }

        return try captureQueue.sync {
            do {
                for writer in writers.values {
                    if let chunk = try writer.finish() {
                        manifest?.append(chunk)
                        try saveManifest()
                    }
                }
                if let stopError {
                    throw stopError
                }
                if let preservedFailure {
                    manifest?.setStatus(.failed, error: preservedFailure)
                    try saveManifest()
                    reset()
                    throw RecordingCoordinatorError.recordingFailed(preservedFailure)
                }
                manifest?.setStatus(.readyForProcessing)
                try saveManifest()
                guard let workspace, let manifest else { throw AudioCaptureError.notRecording }
                let result = RecordingResult(workspace: workspace, manifest: manifest)
                reset()
                return result
            } catch {
                if manifest != nil {
                    recordFailure("録音の確定に失敗しました: \(error.localizedDescription)")
                    reset()
                }
                throw error
            }
        }
    }

    func audioInputSnapshot() -> [AudioTrack: AudioInputSnapshot] {
        captureQueue.sync { inputLevels }
    }

    func setMaximumDuration(seconds: Int) throws {
        try captureQueue.sync {
            let bounded = min(RecordingLimit.maximumSeconds, max(60, seconds))
            if var updated = manifest, let workspace {
                updated.setMaximumDuration(seconds: bounded)
                try manifestStore.save(updated, to: workspace.manifestURL)
                manifest = updated
            }
            configuredMaximumSeconds = bounded
        }
    }

    private func prepare(
        title: String,
        mode: CaptureMode,
        languageMode: LanguageMode,
        tracks: [AudioTrack]
    ) throws -> RecordingWorkspacePaths {
        try captureQueue.sync {
            guard manifest == nil else { throw AudioCaptureError.alreadyRecording }
            let sessionID = UUID()
            let startedAt = Date.now
            try RecordingStorageValidator().validate(root: workspaceRoot)
            let paths = RecordingWorkspacePaths(
                root: workspaceRoot,
                startedAt: startedAt,
                title: title,
                sessionID: sessionID
            )
            try paths.createDirectories(tracks: tracks)
            let newManifest = RecordingManifest(
                sessionID: sessionID,
                title: title,
                captureMode: mode,
                languageMode: languageMode,
                startedAt: startedAt,
                tracks: tracks,
                chunkDurationSeconds: Self.chunkDurationSeconds,
                maximumDurationSeconds: configuredMaximumSeconds
            )
            try manifestStore.save(newManifest, to: paths.manifestURL)
            workspace = paths
            manifest = newManifest
            writers = Dictionary(uniqueKeysWithValues: tracks.map { track in
                (track, ChunkedAudioWriter(
                    paths: paths,
                    track: track,
                    chunkDurationSeconds: Self.chunkDurationSeconds
                ))
            })
            inputLevels = Dictionary(uniqueKeysWithValues: tracks.map {
                ($0, AudioInputSnapshot(level: .init(rms: 0, peak: 0), receivedAt: .distantPast, lastSoundAt: nil))
            })
            timelineOriginSeconds = nil
            didReportFailure = false
            acceptsSamples = true
            return paths
        }
    }

    private func consume(_ sampleBuffer: CMSampleBuffer, track: AudioTrack) {
        dispatchPrecondition(condition: .onQueue(captureQueue))
        guard acceptsSamples, let writer = writers[track] else { return }
        do {
            let buffer = try SampleBufferAudioConverter.pcmBuffer(from: sampleBuffer)
            let level = AudioInputMeter.measure(buffer)
            let receivedAt = Date.now
            inputLevels[track] = .init(level: level, receivedAt: receivedAt,
                lastSoundAt: level.hasSound ? receivedAt : inputLevels[track]?.lastSoundAt)
            let presentationSeconds = SampleBufferAudioConverter.presentationSeconds(of: sampleBuffer)
            if timelineOriginSeconds == nil {
                timelineOriginSeconds = presentationSeconds
            }
            let timestampMilliseconds: Int64
            if let presentationSeconds, let origin = timelineOriginSeconds {
                timestampMilliseconds = max(0, Int64(((presentationSeconds - origin) * 1_000).rounded()))
            } else {
                timestampMilliseconds = 0
            }
            if let chunk = try writer.append(
                buffer,
                sessionTimestampMilliseconds: timestampMilliseconds
            ) {
                manifest?.append(chunk)
                try saveManifest()
            }
        } catch {
            recordFailure("音声チャンクを書き込めませんでした: \(error.localizedDescription)")
        }
    }

    private func saveManifest() throws {
        guard let workspace, let manifest else { throw AudioCaptureError.notRecording }
        try manifestStore.save(manifest, to: workspace.manifestURL)
    }

    private func recordFailure(_ message: String) {
        dispatchPrecondition(condition: .onQueue(captureQueue))
        acceptsSamples = false
        manifest?.setStatus(.failed, error: message)
        try? saveManifest()
        guard !didReportFailure else { return }
        didReportFailure = true
        failureHandler(message)
    }

    private func reset() {
        workspace = nil
        manifest = nil
        writers = [:]
        inputLevels = [:]
        timelineOriginSeconds = nil
        acceptsSamples = false
        didReportFailure = false
    }
}
