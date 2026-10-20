// Appended to an isolated copy of RecallCaptureApp.swift by verify-ui.sh.
// Uses the real views with fixtures; never starts capture or changes user settings.
extension AppModel {
    func prepareUIFixture(state: SessionState, root: URL) {
        self.state = state
        isProcessing = state == .diarizing
        saveDirectoryURL = root.appendingPathComponent("会議の記録")
        microphones = [.init(id: "fixture", name: "内蔵マイク")]
        permissionSnapshot = .init(microphone: .authorized, screenRecording: .authorized, speechRecognition: .authorized)
        message = "録音を開始できます。"
        if state == .recording || isProcessing {
            startedAt = Date(timeIntervalSince1970: 1_800_000_000)
            now = startedAt!.addingTimeInterval(3_720)
            remainingSeconds = 240
            limitWarning = "あと5分で自動停止します。音声が続いています。必要なら延長してください。"
            inputLevels = [.system: .init(level: .init(rms: 0.12, peak: 0.35), receivedAt: now, lastSoundAt: now),
                           .microphone: .init(level: .init(rms: 0, peak: 0), receivedAt: now, lastSoundAt: nil)]
            message = isProcessing ? "音声から話者を判別しています。" : "録音中です。停止すると話者付きの全文を保存します。"
        }
        if state == .failed {
            recoveryCount = 2
            lastWorkspaceURL = root
            message = "後処理を完了できませんでした。保存済みの全文から後処理を再開できます。"
        }
    }
}

@main
struct UIRenderingCheck {
    @MainActor
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = output.appendingPathComponent("fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for file in ["transcript.md", "transcript.jsonl"] {
            try Data("UI fixture".utf8).write(to: root.appendingPathComponent(file))
        }
        let defaults = UserDefaults(suiteName: "jp.recallcapture.ui-verification")!
        defaults.removePersistentDomain(forName: "jp.recallcapture.ui-verification")
        defer { defaults.removePersistentDomain(forName: "jp.recallcapture.ui-verification") }
        NSApplication.shared.setActivationPolicy(.prohibited)
        for (name, state, size, dark) in [
            ("idle-minimum", SessionState.idle, NSSize(width: 650, height: 600), false),
            ("idle-full", .idle, NSSize(width: 720, height: 1100), false),
            ("recording-dark", .recording, NSSize(width: 720, height: 760), true),
            ("processing", .diarizing, NSSize(width: 720, height: 760), false),
            ("recovery", .failed, NSSize(width: 720, height: 1100), false)
        ] {
            let model = AppModel()
            model.prepareUIFixture(state: state, root: root)
            precondition(model.canStart == (state == .idle || state == .failed))
            if state == .failed { precondition(model.canOpenTranscript) }
            try render(MainWindowView(model: model), size: size, dark: dark, output: output.appendingPathComponent(name + ".png"))
        }
        let settings = AppModel()
        settings.prepareUIFixture(state: .failed, root: root)
        try render(SettingsView(model: settings), size: NSSize(width: 620, height: 680), dark: false,
            output: output.appendingPathComponent("settings.png"), includeBottom: true)
        print("ui-rendering-check: passed (6 states, isolated preferences, no capture)")
    }

    @MainActor
    private static func render<V: View>(_ view: V, size: NSSize, dark: Bool, output: URL, includeBottom: Bool = false) throws {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        hosting.layoutSubtreeIfNeeded()
        try snapshot(hosting, to: output)
        if includeBottom, let scroll = findScroll(hosting), let document = scroll.documentView {
            document.scroll(NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            hosting.layoutSubtreeIfNeeded()
            try snapshot(hosting, to: output.deletingPathExtension().appendingPathExtension("bottom.png"))
        }
        window.contentView = nil
    }

    @MainActor
    private static func findScroll(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews { if let scroll = findScroll(child) { return scroll } }
        return nil
    }

    @MainActor
    private static func snapshot(_ view: NSView, to output: URL) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: output)
    }
}
