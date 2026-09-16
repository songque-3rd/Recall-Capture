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
        .defaultSize(width: 600, height: 560)

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
        screenRecording: .notDetermined
    )
    @Published private(set) var message = "録音を開始できます。"
    @Published private(set) var isStarting = false
    @Published private(set) var isStopping = false
    @Published private(set) var isProcessing = false
    @Published private var now = Date()
    @Published var languageMode = LanguageMode.japanese

    private let permissionService = CapturePermissionService()
    private let destinationStore: RecordingDestinationStore
    private let recentRecordingStore: RecentRecordingStore
    private var stateMachine = SessionStateMachine()
    private var activeWorkspace: RecordingWorkspacePaths?
    private var clockTask: Task<Void, Never>?
    private var automaticStopTask: Task<Void, Never>?
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
        refreshPermissions()
        refreshMicrophones()
        refreshRecoveryCandidates()
    }

    deinit {
        clockTask?.cancel()
        automaticStopTask?.cancel()
    }

    var isRecording: Bool { state == .recording }
    var canStart: Bool { state == .idle && !isStarting && !isStopping && !isProcessing }
    var usesAdHocSigning: Bool {
        Bundle.main.object(forInfoDictionaryKey: "RecallCaptureSigningMode") as? String == "ad-hoc"
    }

    var elapsedDescription: String {
        guard let startedAt else { return "--:--:--" }
        let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
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
        if permissionSnapshot.screenRecording == .denied {
            message = screenRecordingRecoveryMessage
        } else if permissionSnapshot.microphone == .denied {
            message = "マイクが未許可です。マイク設定でRecall Captureをオンにしてください。"
        } else {
            message = "マイクと画面収録の権限を確認できました。"
        }
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
        cancelTimers()
        if state == .recording {
            try? transition(to: .finalizingAudio)
        }
        message = automatic
            ? "3時間に達したため録音を自動停止し、音声を確定しています…"
            : "録音を停止し、音声を確定しています…"

        Task {
            do {
                let result = try await coordinator.stop()
                setLastWorkspace(result.workspace.directory)
                activeWorkspace = nil
                startedAt = nil
                isStopping = false
                message = automatic
                    ? "3時間で自動停止しました。文字起こしを開始します…"
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
        message = "保存済み音声から後処理を再開します…"
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
            message = "文字起こし（\(result.utteranceCount)件）と要約PDFを作成しました。"
        } catch {
            if state != .failed {
                try? transition(to: .failed)
            }
            stateMachine = SessionStateMachine()
            state = .idle
            message = "後処理を完了できませんでした: \(error.localizedDescription)"
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
            case .summarizingChunks: "発話の要点を抽出しています…"
            case .summarizingOverall: "全体要約を組み立てています…"
            case .writingArtifacts: "文字起こしJSONLと要約PDFを書き出しています…"
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
            let location = SessionLocation(directory: candidate.paths.directory)
            let hasTranscript = FileManager.default.fileExists(atPath: location.transcriptJSONL.path)
            let hasPDF = FileManager.default.fileExists(atPath: location.summaryPDF.path)
            return !(hasTranscript && hasPDF)
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

    private func openPrivacySettings(anchor: String, name: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ), NSWorkspace.shared.open(url) else {
            message = "システム設定の\(name)権限を開けませんでした。"
            return
        }
        if anchor == "Privacy_ScreenCapture" {
            message = "画面収録設定の変更は再起動後に反映されます。Recall Captureを完全終了してから起動し直してください。"
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

    private func startTimers() {
        clockTask?.cancel()
        clockTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                now = .now
            }
        }

        automaticStopTask?.cancel()
        automaticStopTask = Task {
            try? await Task.sleep(for: .seconds(RecordingCoordinator.maximumDurationSeconds))
            guard !Task.isCancelled else { return }
            stopRecording(automatic: true)
        }
    }

    private func cancelTimers() {
        clockTask?.cancel()
        automaticStopTask?.cancel()
        clockTask = nil
        automaticStopTask = nil
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
            Text(model.isProcessing ? "後処理中" : "録音中  \(model.elapsedDescription)")
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
            VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: model.isRecording ? "record.circle.fill" : "waveform")
                    .font(.title)
                    .foregroundStyle(model.isRecording ? .red : .primary)
                Text("Recall Capture")
                    .font(.title)
                Spacer()
                SettingsLink {
                    Label("設定", systemImage: "gearshape")
                }
                .accessibilityLabel("設定を開く")
            }

            LabeledContent("現在の状態", value: model.state.rawValue)
            LabeledContent("録音時間", value: model.elapsedDescription)
            LabeledContent("復旧候補", value: "\(model.recoveryCount)件")
            Text(model.message)
                .foregroundStyle(.secondary)

            Divider()

            GroupBox("保存先") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.saveDirectoryURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                    HStack {
                        Button("Finderで開く") {
                            model.openSaveDirectory()
                        }
                        .accessibilityLabel("保存先をFinderで開く")
                        Button("変更…") {
                            model.chooseSaveDirectory()
                        }
                        .accessibilityLabel("保存先を変更")
                        .disabled(!model.canStart)
                        Spacer()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            Text("録音操作")
                .font(.headline)

            if model.isRecording || model.isStopping || model.isProcessing {
                Button(model.isProcessing ? "後処理中…" : (model.isStopping ? "停止処理中…" : "録音停止")) {
                    model.stopRecording()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(model.isStopping || model.isProcessing)
            } else {
                HStack(spacing: 12) {
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
                    .accessibilityLabel("オンライン会議を録音")

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
                    .accessibilityLabel("対面授業を録音")
                }
                .disabled(!model.canStart)
            }

            if model.recoveryCount > 0 {
                Button("保存済み音声の後処理を再開") {
                    model.resumePostProcessing()
                }
                .disabled(!model.canStart)
            }

            if let url = model.lastWorkspaceURL {
                Text("直近の保存先")
                    .font(.headline)
                HStack {
                    Text(url.path)
                        .font(.caption)
                        .textSelection(.enabled)
                        .lineLimit(2)
                    Spacer()
                    Button("Finderで表示") {
                        model.revealLastWorkspace()
                    }
                    .accessibilityLabel("直近の録音をFinderで表示")
                }
            }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 560, minHeight: 500)
    }
}

private struct SettingsView: View {
    @ObservedObject var model: AppModel

    private func permissionText(_ state: CapturePermissionState) -> String {
        switch state {
        case .notDetermined: "未確認"
        case .authorized: "許可済み"
        case .denied: "未許可"
        }
    }

    var body: some View {
        Form {
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
            Section("録音") {
            Picker("言語", selection: $model.languageMode) {
                Text("日本語").tag(LanguageMode.japanese)
                Text("日本語＋英語").tag(LanguageMode.japaneseAndEnglish)
            }
            LabeledContent(
                "マイク権限",
                value: permissionText(model.permissionSnapshot.microphone)
            )
            LabeledContent(
                "画面収録権限",
                value: permissionText(model.permissionSnapshot.screenRecording)
            )
            HStack {
                Button("権限を再確認") {
                    model.recheckPermissions()
                }
                Button("マイク設定") {
                    model.openMicrophonePrivacySettings()
                }
                Button("画面収録設定") {
                    model.openScreenRecordingPrivacySettings()
                }
                Button("音声認識設定") {
                    model.openSpeechRecognitionPrivacySettings()
                }
                Button("音声入力設定") {
                    model.openDictationSettings()
                }
            }
            Text("文字起こしには、音声認識権限に加えて、キーボード設定の『音声入力』をオンにする必要があります。")
                .foregroundStyle(.secondary)
            if model.permissionSnapshot.screenRecording == .denied {
                Text("画面収録設定の変更は、Recall Captureを完全終了して起動し直すまで反映されません。再起動後も未許可なら、設定を一度オフ→オンにしてもう一度再起動してください。")
                    .foregroundStyle(.orange)
            }
            if model.usesAdHocSigning {
                Text("このアプリは開発用の一時署名です。再ビルド後は画面収録を再許可する必要があります。継続利用には同じApple Development証明書でビルドしてください。")
                    .foregroundStyle(.secondary)
            }
            Text("外部AI: 使用しない（既定）")
            Text("音声は60秒チャンクで一時保存し、3時間で自動停止します。")
                .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear {
            model.refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
    }
}
