import AppKit
import CaptureCore
import SwiftUI

@main
struct RecallCaptureApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Recall Capture", id: "main") {
            MainWindowView(model: model)
                .task {
                    model.handleLaunchArgumentsIfNeeded()
                }
        }
        .defaultSize(width: 720, height: 760)

        MenuBarExtra {
            CaptureMenu(model: model)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.isRecording ? "record.circle.fill" : "waveform")
                Text(model.isRecording ? "REC" : "Recall")
            }
            .accessibilityLabel("Recall Capture")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--microphone-smoke-check") {
            runMicrophoneSmokeCheck()
            return
        }
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func runMicrophoneSmokeCheck() {
        let receivedSample = DispatchSemaphore(value: 0)
        let engine = ClassroomCaptureEngine(
            captureQueue: DispatchQueue(label: "jp.recallcapture.microphone-smoke-samples"),
            sampleHandler: { _, _ in receivedSample.signal() }
        )

        DispatchQueue(label: "jp.recallcapture.microphone-smoke-control").async {
            do {
                try engine.start(deviceID: nil)
                let didReceiveSample = receivedSample.wait(timeout: .now() + 5) == .success
                engine.stop()
                guard didReceiveSample else {
                    Self.finishMicrophoneSmokeCheck(
                        message: "microphone-smoke-check: failed (no audio sample received)",
                        status: 1
                    )
                    return
                }
                Self.finishMicrophoneSmokeCheck(
                    message: "microphone-smoke-check: passed",
                    status: 0
                )
            } catch {
                engine.stop()
                Self.finishMicrophoneSmokeCheck(
                    message: "microphone-smoke-check: failed (\(error.localizedDescription))",
                    status: 1
                )
            }
        }
    }

    nonisolated private static func finishMicrophoneSmokeCheck(message: String, status: Int32) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(status)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state = SessionState.idle
    @Published private(set) var startedAt: Date?
    @Published private(set) var meetWindows: [MeetWindowDescriptor] = []
    @Published private(set) var microphones: [MicrophoneDescriptor] = []
    @Published private(set) var recoveryCount = 0
    @Published private(set) var lastWorkspaceURL: URL?
    @Published private(set) var saveDirectoryURL: URL
    @Published private(set) var permissionSnapshot = CapturePermissionSnapshot(
        microphone: .notDetermined,
        screenRecording: .unconfirmed
    )
    @Published private(set) var message = "録音を開始できます。"
    @Published private(set) var isStarting = false
    @Published private(set) var isStopping = false
    @Published private(set) var isProcessing = false
    @Published private var now = Date()
    @Published var languageMode = LanguageMode.japanese {
        didSet { UserDefaults.standard.set(languageMode.rawValue, forKey: "recognitionLanguage") }
    }
    @Published var recordingLimitMinutes = 120 {
        didSet { UserDefaults.standard.set(recordingLimitMinutes, forKey: "recordingLimitMinutes") }
    }
    @Published private(set) var remainingSeconds = RecordingLimit.defaultSeconds
    @Published private(set) var inputLevels: [AudioTrack: AudioInputSnapshot] = [:]
    @Published private(set) var limitWarning: String?
    private var recordingLimit = RecordingLimit()
    private var recordingClockStart: ContinuousClock.Instant?
    private lazy var notifications = RecordingNotifications()

    private let permissionService = CapturePermissionService()
    private let destinationStore: RecordingDestinationStore
    private let recentRecordingStore: RecentRecordingStore
    private var stateMachine = SessionStateMachine()
    private var activeWorkspace: RecordingWorkspacePaths?
    private var clockTask: Task<Void, Never>?
    private var didHandleLaunchArguments = false

    private lazy var coordinator = RecordingCoordinator(workspaceRoot: saveDirectoryURL) { [weak self] errorMessage in
        Task { @MainActor [weak self] in
            await self?.handleCaptureFailure(errorMessage)
        }
    }
    private let postProcessor = PostProcessingCoordinator()

    init() {
        let destinationStore = RecordingDestinationStore()
        let recentRecordingStore = RecentRecordingStore()
        self.destinationStore = destinationStore
        self.recentRecordingStore = recentRecordingStore
        saveDirectoryURL = destinationStore.load(defaultURL: RecordingCoordinator.defaultWorkspaceRoot())
        lastWorkspaceURL = recentRecordingStore.load()
        languageMode = LanguageMode(rawValue: UserDefaults.standard.string(forKey: "recognitionLanguage") ?? "") ?? .japanese
        let savedMinutes = UserDefaults.standard.integer(forKey: "recordingLimitMinutes")
        recordingLimitMinutes = savedMinutes == 0 ? 120 : min(720, max(5, savedMinutes))
        refreshPermissions()
        refreshMicrophones()
        refreshRecoveryCandidates()
    }

    deinit {
        clockTask?.cancel()
    }

    var isRecording: Bool { state == .recording }
    var canStart: Bool { (state == .idle || state == .failed) && !isStarting && !isStopping && !isProcessing }
    var canOpenTranscript: Bool { artifactExists("transcript.md") || artifactExists("transcript.jsonl") }
    var statusLabel: String {
        if isStarting { return "録音を準備中" }
        if isStopping { return "音声を保存中" }
        if isProcessing {
            return switch state {
            case .detectingSpeech, .transcribing: "文字起こし中"
            case .diarizing: "話者を整理中"
            case .formatting: "全文を整形中"
            case .writingArtifacts, .validatingArtifacts: "成果物を保存中"
            default: "後処理中"
            }
        }
        return isRecording ? "録音中" : (state == .failed ? "録音の復旧が必要" : "録音の準備ができています")
    }
    var usesAdHocSigning: Bool {
        Bundle.main.object(forInfoDictionaryKey: "RecallCaptureSigningMode") as? String == "ad-hoc"
    }

    var elapsedDescription: String {
        guard let startedAt else { return "--:--:--" }
        let seconds = max(0, Int(isRecording ? recordingElapsedSeconds : now.timeIntervalSince(startedAt)))
        return String(
            format: "%02d:%02d:%02d",
            seconds / 3_600,
            seconds / 60 % 60,
            seconds % 60
        )
    }

    func refreshMeetWindows() {
        guard !isStarting, !isStopping, !isProcessing else { return }
        guard requestScreenRecordingPermission() else {
            message = screenRecordingRecoveryMessage
            return
        }
        isStarting = true
        message = "録音できるオンライン会議ウインドウを確認しています…"
        Task {
            defer { isStarting = false }
            do {
                meetWindows = try await MeetCaptureEngine.availableWindows()
                message = meetWindows.isEmpty
                    ? "録音できるMeet / Zoom / Discordウインドウが見つかりません。"
                    : "録音するオンライン会議ウインドウを選択してください。"
            } catch {
                message = "ウインドウ一覧を取得できませんでした: \(error.localizedDescription)"
            }
        }
    }

    func refreshMicrophones() {
        microphones = ClassroomCaptureEngine.availableMicrophones()
    }

    func refreshPermissions() {
        permissionSnapshot = permissionService.snapshot()
    }

    func recheckPermissions() {
        refreshPermissions()
        if permissionSnapshot.screenRecording == .unconfirmed {
            message = screenRecordingRecoveryMessage
        } else if permissionSnapshot.microphone == .denied {
            message = "マイクが未許可です。マイク設定でRecall Captureをオンにしてください。"
        } else if permissionSnapshot.speechRecognition != .authorized {
            message = "音声認識が未許可です。録音開始時に確認し、拒否済みの場合は設定から変更してください。"
        } else if permissionSnapshot.microphone == .authorized && permissionSnapshot.screenRecording == .authorized {
            message = "マイク・画面収録・音声認識の権限を確認できました。"
        } else {
            message = "権限の状態を更新しました。録音開始時に必要な許可を確認します。"
        }
    }

    func openUsageGuide() {
        guard let url = Bundle.main.url(forResource: "UsageGuide", withExtension: "md") else {
            message = "利用手順が見つかりません。READMEの起動手順を確認してください。"
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openMicrophonePrivacySettings() {
        openPrivacySettings(anchor: "Privacy_Microphone", name: "マイク")
    }

    func openScreenRecordingPrivacySettings() {
        openPrivacySettings(anchor: "Privacy_ScreenCapture", name: "画面収録")
    }

    func openSpeechRecognitionPrivacySettings() {
        openPrivacySettings(anchor: "Privacy_SpeechRecognition", name: "音声認識")
    }

    func openDictationSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
        ), NSWorkspace.shared.open(url) else {
            message = "システム設定のキーボード設定を開けませんでした。"
            return
        }
        message = "キーボード設定の『音声入力』をオンにしてから、後処理を再開してください。"
    }

    func refreshRecoveryCandidates() {
        recoveryCount = actionableRecoveryCandidates().count
    }

    func chooseSaveDirectory() {
        guard canStart else {
            message = "録音中は保存先を変更できません。"
            return
        }
        let panel = NSOpenPanel()
        panel.title = "録音の保存先を選択"
        panel.prompt = "このフォルダを使用"
        panel.message = "新しい録音は、このフォルダ内の年・月別フォルダへ保存されます。既存の録音は移動しません。"
        panel.directoryURL = saveDirectoryURL
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        applySaveDirectory(selectedURL)
    }

    func resetSaveDirectory() {
        guard canStart else {
            message = "録音中は保存先を変更できません。"
            return
        }
        let defaultURL = RecordingCoordinator.defaultWorkspaceRoot()
        do {
            try RecordingStorageValidator().validate(root: defaultURL)
            try coordinator.updateWorkspaceRoot(defaultURL)
            destinationStore.clear()
            saveDirectoryURL = defaultURL.standardizedFileURL
            refreshRecoveryCandidates()
            message = "保存先を標準フォルダへ戻しました。既存の録音は移動していません。"
        } catch {
            message = "標準の保存先を使用できません: \(error.localizedDescription)"
        }
    }

    func openSaveDirectory() {
        do {
            try RecordingStorageValidator().validate(root: saveDirectoryURL)
            NSWorkspace.shared.open(saveDirectoryURL)
        } catch {
            message = "保存先を開けません: \(error.localizedDescription)"
        }
    }

    private func artifactExists(_ name: String) -> Bool {
        guard let lastWorkspaceURL else { return false }
        return FileManager.default.fileExists(atPath: lastWorkspaceURL.appendingPathComponent(name).path)
    }

    func openTranscript() {
        guard let lastWorkspaceURL, canOpenTranscript else { return }
        let location = SessionLocation(directory: lastWorkspaceURL)
        do {
            // Older completed sessions can gain Markdown without rerunning recognition.
            if !artifactExists("transcript.md") {
                let transcript = try TranscriptJSONLWriter().read(from: location.transcriptJSONL)
                try TranscriptMarkdownWriter().write(
                    metadata: transcript.metadata, utterances: transcript.utterances,
                    to: location.transcriptMarkdown
                )
            }
            if !NSWorkspace.shared.open(location.transcriptMarkdown) {
                NSWorkspace.shared.activateFileViewerSelecting([location.transcriptMarkdown])
            }
        } catch {
            message = "文字起こし全文を開けません: \(error.localizedDescription)"
        }
    }

    func revealLastWorkspace() {
        guard let lastWorkspaceURL else {
            message = "完了した録音はまだありません。"
            return
        }
        guard FileManager.default.fileExists(atPath: lastWorkspaceURL.path) else {
            recentRecordingStore.clear()
            self.lastWorkspaceURL = nil
            message = "直近の録音フォルダが見つかりません。移動または削除された可能性があります。"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([lastWorkspaceURL])
    }

    func beginMeet(window: MeetWindowDescriptor, microphoneID: String? = nil) {
        guard canStart else { return }
        isStarting = true
        message = "\(window.applicationName)の録音を開始しています…"
        Task {
            defer { isStarting = false }
            guard prepareStorageForRecording() else { return }
            guard requestScreenRecordingPermission() else {
                message = screenRecordingRecoveryMessage
                return
            }
            guard await requestMicrophonePermission() else {
                message = "このRecall Captureからマイクを利用できません。設定画面で権限を再確認してください。"
                return
            }
            guard await requestSpeechRecognitionPermission() else {
                message = "文字起こしには音声認識の許可が必要です。音声認識設定でRecall Captureを許可してください。端末の管理制限がある場合は管理者へ確認してください。"
                return
            }
            do {
                let workspace = try await coordinator.startMeet(
                    windowID: window.id,
                    microphoneDeviceID: microphoneID,
                    title: window.title.isEmpty ? window.applicationName : window.title,
                    languageMode: languageMode
                )
                try enterRecording(workspace: workspace)
                message = "\(window.applicationName)を録音中です。"
            } catch {
                await cleanUpFailedStart()
                message = "オンライン会議の録音を開始できませんでした: \(error.localizedDescription)"
            }
        }
    }

    func beginClassroom(microphoneID: String?) {
        guard canStart else { return }
        isStarting = true
        message = "対面授業の録音を開始しています…"
        Task {
            defer { isStarting = false }
            guard prepareStorageForRecording() else { return }
            guard await requestMicrophonePermission() else {
                message = "このRecall Captureからマイクを利用できません。設定画面で権限を再確認してください。"
                return
            }
            guard await requestSpeechRecognitionPermission() else {
                message = "文字起こしには音声認識の許可が必要です。音声認識設定でRecall Captureを許可してください。端末の管理制限がある場合は管理者へ確認してください。"
                return
            }
            do {
                let workspace = try await coordinator.startClassroom(
                    microphoneDeviceID: microphoneID,
                    title: "対面授業",
                    languageMode: languageMode
                )
                try enterRecording(workspace: workspace)
                message = "対面授業を録音中です。"
            } catch {
                await cleanUpFailedStart()
                message = "対面録音を開始できませんでした: \(error.localizedDescription)"
            }
        }
    }

    func stopRecording(automatic: Bool = false) {
        guard activeWorkspace != nil, !isStopping, !isProcessing else { return }
        isStopping = true
        let hasSound = inputLevels.values.contains { $0.hasRecentSound(at: .now) }
        cancelTimers()
        notifications.clearWarnings()
        if automatic { notifications.stopped(hasSound: hasSound) }
        if state == .recording {
            try? transition(to: .finalizingAudio)
        }
        message = automatic
            ? "設定した時間に達したため録音を自動停止し、音声を確定しています…"
            : "録音を停止し、音声を確定しています…"

        Task {
            do {
                let result = try await coordinator.stop()
                setLastWorkspace(result.workspace.directory)
                activeWorkspace = nil
                startedAt = nil
                isStopping = false
                message = automatic
                    ? "上限時間で自動停止しました。文字起こしを開始します…"
                    : "録音を停止しました。文字起こしを開始します…"
                await process(workspace: result.workspace, manifest: result.manifest)
            } catch {
                isStopping = false
                setLastWorkspace(activeWorkspace?.directory)
                state = .failed
                message = "録音音声を保持しましたが、確定処理で問題が発生しました: \(error.localizedDescription)"
                activeWorkspace = nil
                startedAt = nil
                stateMachine = SessionStateMachine()
            }
            refreshRecoveryCandidates()
        }
    }

    func resumePostProcessing() {
        guard canStart, let candidate = actionableRecoveryCandidates().last else { return }
        setLastWorkspace(candidate.paths.directory)
        message = "保存済みデータから後処理を再開します…"
        Task {
            await process(workspace: candidate.paths, manifest: candidate.manifest)
            refreshRecoveryCandidates()
        }
    }

    func handleLaunchArgumentsIfNeeded() {
        guard !didHandleLaunchArguments else { return }
        didHandleLaunchArguments = true
        if CommandLine.arguments.contains("--resume-latest-recording") {
            resumePostProcessing()
        }
    }

    private func process(
        workspace: RecordingWorkspacePaths,
        manifest: RecordingManifest
    ) async {
        isProcessing = true
        setLastWorkspace(workspace.directory)
        defer { isProcessing = false }
        if state == .idle || state == .failed || state == .completed {
            stateMachine = SessionStateMachine()
            state = .idle
        }

        do {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "development"
            let result = try await postProcessor.process(
                workspace: workspace,
                manifest: manifest,
                appVersion: version
            ) { [weak self] nextState in
                await self?.showProcessingState(nextState)
            }
            try transition(to: .completed)
            setLastWorkspace(result.workspace.directory)
            resetToIdle()
            message = "話者付きの全文（\(result.utteranceCount)発話）をMarkdownとJSONLに保存しました。"
            if !result.warnings.isEmpty { message += " " + result.warnings.joined(separator: " ") }
        } catch {
            if state != .failed {
                try? transition(to: .failed)
            }
            stateMachine = SessionStateMachine()
            state = .idle
            message = canOpenTranscript
                ? "全文は保存済みですが、後処理を完了できませんでした: \(error.localizedDescription) 保存済みの全文から再試行できます。"
                : "後処理を完了できませんでした: \(error.localizedDescription)"
        }
    }

    private func showProcessingState(_ nextState: SessionState) {
        do {
            try transition(to: nextState)
            message = switch nextState {
            case .detectingSpeech: "発話を検出しています…"
            case .transcribing: "端末内で文字起こししています…"
            case .diarizing: "音声トラックから話者を整理しています…"
            case .formatting: "文字起こしを整形しています…"
            case .writingArtifacts: "全文Markdown・JSONLを保存しています…"
            case .validatingArtifacts: "作成した成果物を検証しています…"
            default: message
            }
        } catch {
            message = "後処理の状態更新に失敗しました: \(error.localizedDescription)"
        }
    }

    private func actionableRecoveryCandidates() -> [RecordingRecoveryCandidate] {
        RecordingCoordinator.recoveryCandidates(workspaceRoot: saveDirectoryURL).filter { candidate in
            guard !candidate.manifest.chunks.isEmpty,
                  [.readyForProcessing, .processing, .failed].contains(candidate.manifest.status) else {
                return false
            }
            return true
        }
    }

    private func enterRecording(workspace: RecordingWorkspacePaths) throws {
        stateMachine = SessionStateMachine()
        try transition(to: .recording)
        activeWorkspace = workspace
        startedAt = .now
        now = .now
        startTimers()
    }

    private func applySaveDirectory(_ url: URL) {
        let url = url.standardizedFileURL
        do {
            try RecordingStorageValidator().validate(root: url)
            try coordinator.updateWorkspaceRoot(url)
            destinationStore.save(url)
            saveDirectoryURL = url
            refreshRecoveryCandidates()
            message = "保存先を変更しました。次回の録音から使用します。既存の録音は移動していません。"
        } catch {
            message = "選択した保存先を使用できません: \(error.localizedDescription)"
        }
    }

    private func setLastWorkspace(_ url: URL?) {
        lastWorkspaceURL = url
        if let url {
            recentRecordingStore.save(url)
        } else {
            recentRecordingStore.clear()
        }
    }

    private func prepareStorageForRecording() -> Bool {
        do {
            try RecordingStorageValidator().validate(root: saveDirectoryURL)
            try coordinator.updateWorkspaceRoot(saveDirectoryURL)
            try coordinator.setMaximumDuration(seconds: recordingLimitMinutes * 60)
            return true
        } catch {
            message = "録音を開始できません: \(error.localizedDescription)"
            return false
        }
    }

    private func requestScreenRecordingPermission() -> Bool {
        let granted = permissionService.requestScreenRecordingIfNeeded()
        refreshPermissions()
        return granted
    }

    private func requestMicrophonePermission() async -> Bool {
        let granted = await permissionService.requestMicrophoneIfNeeded()
        refreshPermissions()
        return granted
    }

    private func requestSpeechRecognitionPermission() async -> Bool {
        let granted = await permissionService.requestSpeechRecognitionIfNeeded()
        refreshPermissions()
        return granted
    }

    private func openPrivacySettings(anchor: String, name: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ), NSWorkspace.shared.open(url) else {
            message = "システム設定の\(name)権限を開けませんでした。"
            return
        }
        if anchor == "Privacy_ScreenCapture" {
            message = "画面収録を許可し、戻ったら『権限を再確認』を押してください。反映されない場合はRecall Captureを完全終了して起動し直してください。"
        } else {
            message = "システム設定でRecall Captureの\(name)権限を確認し、戻ったら『権限を再確認』を押してください。"
        }
    }

    private var screenRecordingRecoveryMessage: String {
        "画面収録が設定でオンなら、Recall Captureを完全終了して起動し直してください。再起動後も未許可なら、設定を一度オフ→オンにしてもう一度再起動してください。"
    }

    private func transition(to newState: SessionState) throws {
        try stateMachine.transition(to: newState)
        state = stateMachine.state
    }

    var remainingDescription: String {
        String(format: "%02d:%02d:%02d", remainingSeconds / 3_600, remainingSeconds / 60 % 60, remainingSeconds % 60)
    }

    func extendRecording() {
        guard isRecording, !isStopping, recordingLimit.durationSeconds < RecordingLimit.maximumSeconds else { return }
        var extended = recordingLimit
        extended.extend()
        do {
            try coordinator.setMaximumDuration(seconds: extended.durationSeconds)
            recordingLimit = extended
            remainingSeconds = recordingLimit.remaining(elapsedSeconds: recordingElapsedSeconds)
            limitWarning = nil
            notifications.clearWarnings()
            message = "自動停止までの時間を15分延長しました。"
        } catch { message = "延長設定を保存できませんでした: \(error.localizedDescription)" }
    }

    private var recordingElapsedSeconds: Double {
        guard let start = recordingClockStart else { return 0 }
        let parts = start.duration(to: .now).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private func startTimers() {
        clockTask?.cancel()
        recordingClockStart = .now
        recordingLimit = RecordingLimit(seconds: recordingLimitMinutes * 60)
        remainingSeconds = recordingLimit.durationSeconds
        limitWarning = nil
        inputLevels = coordinator.audioInputSnapshot()
        notifications.clearWarnings()
        notifications.prepare { [weak self] in self?.extendRecording() }
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                self.now = .now
                self.inputLevels = self.coordinator.audioInputSnapshot()
                let elapsed = self.recordingElapsedSeconds
                self.remainingSeconds = self.recordingLimit.remaining(elapsedSeconds: elapsed)
                switch self.recordingLimit.poll(elapsedSeconds: elapsed) {
                case let .warning(minutes):
                    let hasSound = self.inputLevels.values.contains { $0.hasRecentSound(at: .now) }
                    self.limitWarning = "あと\(minutes)分で自動停止します。" + (hasSound ? "音声入力が続いています。必要なら延長してください。" : "")
                    self.notifications.warning(minutes: minutes, hasSound: hasSound)
                case .stop:
                    self.stopRecording(automatic: true)
                    return
                case nil: break
                }
            }
        }
    }

    private func cancelTimers() {
        clockTask?.cancel()
        clockTask = nil
    }

    private func resetToIdle() {
        activeWorkspace = nil
        startedAt = nil
        now = .now
        stateMachine = SessionStateMachine()
        state = .idle
    }

    private func cleanUpFailedStart() async {
        if activeWorkspace != nil {
            _ = try? await coordinator.stop()
        }
        activeWorkspace = nil
        startedAt = nil
        stateMachine = SessionStateMachine()
        state = .idle
        cancelTimers()
        refreshRecoveryCandidates()
    }

    private func handleCaptureFailure(_ errorMessage: String) async {
        guard activeWorkspace != nil else { return }
        if state == .recording {
            try? transition(to: .failed)
        } else {
            state = .failed
        }
        message = errorMessage
        stopRecording()
    }
}

private struct CaptureMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.isRecording || model.isStopping || model.isProcessing {
            Text("\(model.statusLabel)  \(model.elapsedDescription)")
            if model.isRecording {
                Text("自動停止まで \(model.remainingDescription)")
                Button("15分延長") { model.extendRecording() }
            }
            Button(model.isProcessing ? "後処理中…" : (model.isStopping ? "停止処理中…" : "録音停止")) {
                model.stopRecording()
            }
            .disabled(model.isStopping || model.isProcessing)
        } else {
            Menu("オンライン会議を録音") {
                ForEach(model.meetWindows) { window in
                    Button(window.label) {
                        model.beginMeet(window: window)
                    }
                }
                if !model.meetWindows.isEmpty {
                    Divider()
                }
                Button("会議ウインドウを読み込む…") {
                    model.refreshMeetWindows()
                }
            }
            .disabled(!model.canStart)

            Menu("対面授業を録音") {
                Button("標準マイク") {
                    model.beginClassroom(microphoneID: nil)
                }
                ForEach(model.microphones) { microphone in
                    Button(microphone.name) {
                        model.beginClassroom(microphoneID: microphone.id)
                    }
                }
                Divider()
                Button("マイク一覧を更新") {
                    model.refreshMicrophones()
                }
            }
            .disabled(!model.canStart)
        }

        if model.recoveryCount > 0 {
            Text("復旧候補: \(model.recoveryCount)件")
            Button("後処理を再開") {
                model.resumePostProcessing()
            }
            .disabled(!model.canStart)
        }
        if !model.message.isEmpty {
            Text(model.message)
        }

        Divider()
        Button("文字起こし全文を開く") { model.openTranscript() }
            .disabled(!model.canOpenTranscript)
        Button("保存先をFinderで開く") {
            model.openSaveDirectory()
        }
        if model.lastWorkspaceURL != nil {
            Button("直近の録音をFinderで表示") {
                model.revealLastWorkspace()
            }
        }
        Divider()
        Button("メイン画面を開く") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        SettingsLink {
            Text("設定")
        }
        Divider()
        Button("終了") {
            NSApp.terminate(nil)
        }
    }
}

private struct MainWindowView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Recall Capture").font(.title2.bold())
                        Text("音声を、話者付きの全文へ")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.openUsageGuide() } label: { Image(systemName: "questionmark.circle") }
                        .help("利用手順を開く")
                        .accessibilityLabel("利用手順を開く")
                    SettingsLink { Image(systemName: "gearshape") }
                        .accessibilityLabel("設定を開く")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Circle()
                                .fill(model.isRecording ? Color.red : Color.accentColor)
                                .frame(width: 9, height: 9)
                            Text(model.statusLabel).font(.headline)
                            Spacer()
                            if model.isStarting || model.isStopping || model.isProcessing {
                                ProgressView().controlSize(.small)
                            }
                            Text(model.elapsedDescription)
                                .font(.title2.monospacedDigit())
                        }
                        if model.isRecording {
                            ForEach(model.inputLevels.keys.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { track in
                                if let snapshot = model.inputLevels[track] {
                                    AudioInputMeterView(track: track, snapshot: snapshot)
                                }
                            }
                            HStack {
                                Text("自動停止まで \(model.remainingDescription)").monospacedDigit()
                                Spacer()
                                Button("15分延長") { model.extendRecording() }
                            }
                            if let warning = model.limitWarning {
                                Label(warning, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                        Text(model.message)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.isRecording || model.isStopping || model.isProcessing {
                            Button(model.isProcessing ? "後処理中…" : (model.isStopping ? "音声を保存中…" : "録音を停止して保存")) {
                                model.stopRecording()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .disabled(model.isStopping || model.isProcessing)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox("次の録音") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 20) {
                            Picker("認識言語", selection: $model.languageMode) {
                                Text("日本語").tag(LanguageMode.japanese)
                                Text("日本語＋英語").tag(LanguageMode.japaneseAndEnglish)
                            }
                            Stepper("自動停止: \(model.recordingLimitMinutes)分", value: $model.recordingLimitMinutes, in: 5...720, step: 5)
                        }
                        .disabled(!model.canStart)
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("オンライン会議", systemImage: "video")
                                    .font(.headline)
                                Text("相手の音声と自分のマイクを記録")
                                    .font(.caption).foregroundStyle(.secondary)
                                Menu("会議ウインドウを選ぶ") {
                                    ForEach(model.meetWindows) { window in
                                        Button(window.label) { model.beginMeet(window: window) }
                                    }
                                    if !model.meetWindows.isEmpty { Divider() }
                                    Button("会議ウインドウを読み込む…") { model.refreshMeetWindows() }
                                }
                                .accessibilityLabel("オンライン会議を録音")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Divider()
                            VStack(alignment: .leading, spacing: 8) {
                                Label("対面授業・会話", systemImage: "mic")
                                    .font(.headline)
                                Text("選んだマイクの音声を記録")
                                    .font(.caption).foregroundStyle(.secondary)
                                Menu("マイクを選んで録音") {
                                    Button("標準マイク") { model.beginClassroom(microphoneID: nil) }
                                    ForEach(model.microphones) { microphone in
                                        Button(microphone.name) { model.beginClassroom(microphoneID: microphone.id) }
                                    }
                                    Divider()
                                    Button("マイク一覧を更新") { model.refreshMicrophones() }
                                }
                                .accessibilityLabel("対面授業を録音")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .disabled(!model.canStart)
                        Text("停止5分前・1分前に通知します。録音中は15分ずつ延長できます。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                GroupBox("直近の録音") {
                    VStack(alignment: .leading, spacing: 12) {
                        if let url = model.lastWorkspaceURL {
                            Text(url.lastPathComponent)
                                .font(.headline).textSelection(.enabled)
                            HStack {
                                Button { model.openTranscript() } label: {
                                    Label("文字起こし全文", systemImage: "text.alignleft")
                                }
                                .disabled(!model.canOpenTranscript)
                                Button("Finderで表示") { model.revealLastWorkspace() }
                            }
                            Text("全文はMarkdown形式。発話時刻・話者・認識の信頼度を確認できます。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("録音が完了すると、ここから話者付きの全文を開けます。")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                if model.recoveryCount > 0 {
                    GroupBox {
                        HStack {
                            Label("未完了の録音が\(model.recoveryCount)件あります", systemImage: "arrow.clockwise")
                            Spacer()
                            Button("後処理を再開") { model.resumePostProcessing() }
                                .disabled(!model.canStart)
                        }
                        .padding(6)
                    }
                }

                DisclosureGroup("保存先") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(model.saveDirectoryURL.path)
                            .font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        HStack {
                            Button("Finderで開く") { model.openSaveDirectory() }
                                .accessibilityLabel("保存先をFinderで開く")
                            Button("変更…") { model.chooseSaveDirectory() }
                                .accessibilityLabel("保存先を変更")
                                .disabled(!model.canStart)
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 650, minHeight: 600)
    }
}

private struct SettingsView: View {
    @ObservedObject var model: AppModel

    private func permissionText(_ state: CapturePermissionState) -> String {
        switch state {
        case .notDetermined: "未申請"
        case .authorized: "許可済み"
        case .denied: "拒否済み"
        case .restricted: "端末の管理により制限"
        case .unconfirmed: "許可を確認できません"
        }
    }

    var body: some View {
        Form {
            Section {
                Button("利用手順を開く") { model.openUsageGuide() }
            }
            Section("保存先") {
                Text(model.saveDirectoryURL.path)
                    .font(.caption)
                    .textSelection(.enabled)
                HStack {
                    Button("変更…") {
                        model.chooseSaveDirectory()
                    }
                    .accessibilityLabel("保存先を変更")
                    .disabled(!model.canStart)
                    Button("Finderで開く") {
                        model.openSaveDirectory()
                    }
                    .accessibilityLabel("保存先をFinderで開く")
                    Button("標準に戻す") {
                        model.resetSaveDirectory()
                    }
                    .accessibilityLabel("保存先を標準に戻す")
                    .disabled(!model.canStart)
                }
                Text("変更は次回の録音から適用され、既存の録音は移動しません。")
                    .foregroundStyle(.secondary)
            }
            Section("認識と録音時間") {
                Picker("言語", selection: $model.languageMode) {
                    Text("日本語").tag(LanguageMode.japanese)
                    Text("日本語＋英語").tag(LanguageMode.japaneseAndEnglish)
                }
                .disabled(!model.canStart)
                Stepper("自動停止: \(model.recordingLimitMinutes)分", value: $model.recordingLimitMinutes, in: 5...720, step: 5)
                    .disabled(!model.canStart)
                Text("停止5分前・1分前に通知します。録音中は15分延長できます。音声入力が続いていても上限で停止します。")
                    .foregroundStyle(.secondary)
            }
            Section("権限とデータ") {
                LabeledContent("マイク", value: permissionText(model.permissionSnapshot.microphone))
                Text("会議での自分の声・対面授業の音声を録音します。両モードで必要です。")
                    .foregroundStyle(.secondary)
                LabeledContent("画面収録", value: permissionText(model.permissionSnapshot.screenRecording))
                Text("オンライン会議のPC音声に必要です。映像は保存しません。対面録音では要求しません。未申請と拒否はmacOSのAPIでは区別できません。")
                    .foregroundStyle(.secondary)
                LabeledContent("音声認識", value: permissionText(model.permissionSnapshot.speechRecognition))
                Text("録音を文字へ変換するために必要です。開始前に確認し、音声は端末内で処理します。")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("権限を再確認") { model.recheckPermissions() }
                    Button("マイク設定") { model.openMicrophonePrivacySettings() }
                    Button("画面収録設定") { model.openScreenRecordingPrivacySettings() }
                }
                HStack {
                    Button("音声認識設定") { model.openSpeechRecognitionPrivacySettings() }
                    Button("音声入力設定") { model.openDictationSettings() }
                }
                Text("通知は停止予告に使います（任意）。許可がなくても録音できます。管理者権限・アカウント・APIキーは不要です。")
                    .foregroundStyle(.secondary)
                if #available(macOS 26.0, *) {
                    Text("SpeechAnalyzerによるオンデバイス認識を使用します。初回のみAppleの言語モデル取得が必要な場合があります。モデルを利用できない場合は従来方式へ切り替えるため、『音声入力』もオンにしてください。")
                        .foregroundStyle(.secondary)
                } else {
                    Text("文字起こしには、音声認識権限に加えて、キーボード設定の『音声入力』をオンにする必要があります。")
                        .foregroundStyle(.secondary)
                }
                if model.permissionSnapshot.screenRecording == .unconfirmed {
                    Text("システム設定で許可後も状態が変わらない場合は、Recall Captureを完全終了して起動し直してください。")
                        .foregroundStyle(.orange)
                }
                if model.usesAdHocSigning {
                    Text("このアプリは開発用の一時署名です。再ビルド後は画面収録を再許可する必要があります。継続利用には同じ署名証明書でビルドしてください。")
                        .foregroundStyle(.secondary)
                }
                Text("Apple Intelligenceは不要です。外部AIサービスへの送信はありません。")
                Text("保存先がiCloudなどの場合、保存後の同期はそのサービスの設定に従います。")
                    .foregroundStyle(.secondary)
                Text("音声は60秒ごとに保存します。初期設定は120分で自動停止です。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 680)
        .onAppear {
            model.refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
    }
}
